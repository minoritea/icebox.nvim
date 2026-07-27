local M = {}

local config    = require("icebox.config")
local store     = require("icebox.store")
local git       = require("icebox.git")
local collector = require("icebox.collector")
local picker    = require("icebox.picker")
local validate  = require("icebox.validate")

-- The zero hash is returned when no cooled commit is available yet.
M.ZERO_HASH = validate.ZERO_HASH
local ZERO_HASH = M.ZERO_HASH

local function warn(msg)
  vim.notify("[icebox] " .. msg, vim.log.levels.WARN)
end

--- Configure icebox.nvim. Optional — if setup() is never called, thaw() uses
--- the built-in defaults (cooldown_days=7, trust_auto_pin=false,
--- branch_commits_per_fetch=500). Per-call overrides on thaw() opts take
--- precedence over both setup values and defaults.
function M.setup(opts)
  config.set(opts or {})
end

-- Expand a GitHub shorthand ("owner/repo") to a full HTTPS URL. All other
-- strings pass through unchanged; downstream validate.url decides what to
-- reject (relative paths, unknown schemes, tilde-prefixed paths, etc.).
-- Callers must pass a string; the guard is enforced upstream.
local function normalize_url(url)
  local owner, repo = url:match("^([a-zA-Z0-9._%-]+)/([a-zA-Z0-9._%-]+)$")
  if owner and repo then
    return "https://github.com/" .. owner .. "/" .. repo .. ".git"
  end
  return url
end

-- Build the fetch_target table passed to git.fetch_*_sync/async. Wraps the
-- "use clone_path if given, else fall back to the icebox-owned cache_dir"
-- choice so callers don't have to repeat it. This helper does not touch
-- thaw state — it just translates opts into fetch arguments.
local function fetch_target_for(url, opts)
  if opts.clone_path then
    return { clone_path = opts.clone_path }
  end
  return { cache_dir = store.cache_dir_for(url) }
end

-- ─── thaw() ─────────────────────────────────────────────────────────────────
--
-- Signatures (exactly these three are accepted; any other shape is a parse
-- error surfaced as WARN + ZERO_HASH):
--   thaw(url_string)                → URL is url_string
--   thaw(url_string, opts_table)    → URL is url_string; opts_table must not carry url/clone_path
--   thaw(opts_table)                → URL comes from opts_table.url or opts_table.clone_path
--
-- opts.clone_path (when set) is the path to an EXISTING external clone
-- (typically maintained by a plugin manager) — NOT an icebox-owned cache.
-- The path must exist and be a git repository; icebox does not create it.
-- Its `origin` remote supplies the URL used for the store key and fetches.
--
-- The three URL sources — the `url` positional argument, `opts.url`, and
-- `opts.clone_path` (via its origin remote) — are MUTUALLY EXCLUSIVE.
-- Specifying more than one is a parse error (WARN + ZERO_HASH). Specifying
-- none is also an error.
--
-- Resolution proceeds in six steps:
--   1. Sync fetch when the store file does not exist yet.
--   2. Sync fetch when the store exists but this route has not been fetched.
--   3. Otherwise schedule a bg fetch (fires after every other step,
--      regardless of whether they succeed).
--   4. Collect the candidate set for the resolved route.
--   5. When trust_auto_pin is on, record or read the auto pin.
--   6. Delegate to picker.pick for the 3-way winner.

-- Internal implementation. Returns (result_hash, bg_fetch_fn or nil).
-- The bg_fetch_fn, when non-nil, is invoked by the outer wrapper via
-- vim.schedule after all other work completes — including error returns —
-- so that a failed thaw still keeps the store fresh for the next call.
local function thaw_impl(url_or_opts, opts)
  -- Canonicalize the call shape. Exactly three are accepted:
  --   thaw(url)        : url_or_opts is a string, opts is nil
  --   thaw(url, opts)  : url_or_opts is a string, opts is a table
  --   thaw(opts)       : url_or_opts is a table,  opts is nil
  local url = nil
  local t1, t2 = type(url_or_opts), type(opts)
  if t1 == "string" and t2 == "nil" then
    url = url_or_opts
  elseif t1 == "string" and t2 == "table" then
    url = url_or_opts
  elseif t1 == "table" and t2 == "nil" then
    opts = url_or_opts
  else
    warn("invalid thaw() call: expected thaw(url), thaw(url, opts), or thaw(opts); got ("
         .. t1 .. ", " .. t2 .. ")")
    return ZERO_HASH, nil
  end

  -- Parse opts first (may contain url / clone_path).
  local parsed_opts, opts_err = validate.opts(opts)
  if not parsed_opts then
    warn(opts_err or "invalid opts")
    return ZERO_HASH, nil
  end
  opts = parsed_opts

  -- Resolve URL. The three sources (url arg, opts.url, opts.clone_path) are
  -- mutually exclusive. Multiple → parse error. None → parse error.
  local sources = {}
  if type(url) == "string" then sources[#sources + 1] = "url argument" end
  if type(opts.url) == "string" then sources[#sources + 1] = "opts.url" end
  if opts.clone_path then sources[#sources + 1] = "opts.clone_path" end

  if #sources > 1 then
    warn("only one of url argument / opts.url / opts.clone_path may be specified, got: "
         .. table.concat(sources, ", "))
    return ZERO_HASH, nil
  end
  if #sources == 0 then
    warn("no URL provided: pass a URL string, opts.url, or opts.clone_path")
    return ZERO_HASH, nil
  end

  local resolved_url
  if opts.clone_path then
    local origin, origin_err = git.origin_url(opts.clone_path)
    if not origin then
      warn("clone_path: " .. (origin_err or ""))
      return ZERO_HASH, nil
    end
    resolved_url = normalize_url(origin)
  elseif type(url) == "string" then
    resolved_url = normalize_url(url)
  else
    resolved_url = normalize_url(opts.url)
  end

  local url_ok, url_err = validate.url(resolved_url)
  if not url_ok then
    warn("invalid url: " .. (url_err or ""))
    return ZERO_HASH, nil
  end
  url = resolved_url

  -- Effective cfg (per-call overrides win over setup values).
  local cfg = config.merge_overrides({
    cooldown_days            = opts.cooldown_days,
    trust_auto_pin           = opts.trust_auto_pin,
    branch_commits_per_fetch = opts.branch_commits_per_fetch,
  })
  local cooldown_sec = cfg.cooldown_days * 86400
  local now          = os.time()

  -- Bg fetch scheduled by step 3. Returned to the outer wrapper so it fires
  -- after every other step, including error returns.
  local bg_fetch_fn = nil

  -- Steps 1/2/3: decide whether to run a sync fetch now, or defer to
  -- background. Only one of the three fires.
  local initial_fetched_key
  if opts.branch then
    initial_fetched_key = "branch:" .. opts.branch
  elseif opts.version then
    initial_fetched_key = "version:" .. opts.version
  else
    initial_fetched_key = "default"
  end

  local data
  if not store.exists(url) then
    -- Step 1: store file does not exist yet → sync fetch for opts.
    local ok, err
    if opts.branch then
      ok, err = git.fetch_branch_sync(url, opts.branch,
        cfg.branch_commits_per_fetch, fetch_target_for(url, opts))
    elseif opts.version then
      ok, err = git.fetch_tags_sync(url)
    else
      ok, err = git.fetch_default_sync(url,
        cfg.branch_commits_per_fetch, fetch_target_for(url, opts))
    end
    if not ok then
      warn("sync fetch failed: " .. (err or "unknown"))
      return ZERO_HASH, nil
    end

    -- Reload the store after the fetch persisted `new_data`, then record
    -- initial_fetched for this call's key.
    local read_err
    data, read_err = store.read(url)
    if not data then
      warn("store read failed: " .. (read_err or ""))
      return ZERO_HASH, nil
    end
    store.mark_initial_fetched(data, initial_fetched_key)
    -- For the fallback route the fetch also fully populates whichever
    -- concrete route the fallback ends up on; mark that route as fetched
    -- too so a later thaw with `branch = <default>` does not fire again.
    if initial_fetched_key == "default" then
      if store.has_semver_tags(data) then
        store.mark_initial_fetched(data, "version:>=0.0.0")
      elseif data.default_branch then
        store.mark_initial_fetched(data, "branch:" .. data.default_branch)
      end
    end
    local wok, werr = store.write(url, data)
    if not wok then
      warn("store write failed: " .. (werr or ""))
      return ZERO_HASH, nil
    end
  else
    local read_err
    data, read_err = store.read(url)
    if not data then
      warn("store read failed: " .. (read_err or ""))
      return ZERO_HASH, nil
    end
    if not store.is_initial_fetched(data, initial_fetched_key) then
      -- Step 2: store exists but this route has not been fetched → sync fetch.
      local ok, err
      if opts.branch then
        ok, err = git.fetch_branch_sync(url, opts.branch,
          cfg.branch_commits_per_fetch, fetch_target_for(url, opts))
      elseif opts.version then
        ok, err = git.fetch_tags_sync(url)
      else
        ok, err = git.fetch_default_sync(url,
          cfg.branch_commits_per_fetch, fetch_target_for(url, opts))
      end
      if not ok then
        warn("sync fetch failed: " .. (err or "unknown"))
        return ZERO_HASH, nil
      end

      data, read_err = store.read(url)
      if not data then
        warn("store read failed: " .. (read_err or ""))
        return ZERO_HASH, nil
      end
      store.mark_initial_fetched(data, initial_fetched_key)
      if initial_fetched_key == "default" then
        if store.has_semver_tags(data) then
          store.mark_initial_fetched(data, "version:>=0.0.0")
        elseif data.default_branch then
          store.mark_initial_fetched(data, "branch:" .. data.default_branch)
        end
      end
      local wok, werr = store.write(url, data)
      if not wok then
        warn("store write failed: " .. (werr or ""))
        return ZERO_HASH, nil
      end
    else
      -- Step 3: sync fetch was not needed → arm a bg fetch for the outer
      -- wrapper. Fires regardless of what steps 4–6 return.
      bg_fetch_fn = function()
        if opts.branch then
          git.fetch_branch_async(url, opts.branch,
            cfg.branch_commits_per_fetch, fetch_target_for(url, opts))
        elseif opts.version then
          git.fetch_tags_async(url)
        else
          git.fetch_default_async(url,
            cfg.branch_commits_per_fetch, fetch_target_for(url, opts))
        end
      end
    end
  end

  -- Step 4: collect the candidate set for the resolved route.
  local candidates
  local auto_pin_key
  if opts.branch then
    auto_pin_key = "branch:" .. opts.branch
    candidates   = collector.from_branch(data, opts.branch)
  elseif opts.version then
    auto_pin_key = "version:" .. opts.version
    candidates   = collector.from_version(data, opts.version, opts.normalize)
  elseif store.has_semver_tags(data) then
    auto_pin_key = "version:>=0.0.0"
    candidates   = collector.from_version(data, ">=0.0.0", opts.normalize)
  elseif data.default_branch then
    auto_pin_key = "branch:" .. data.default_branch
    candidates   = collector.from_branch(data, data.default_branch)
  else
    warn("upstream has neither semver tags nor a known default branch")
    return ZERO_HASH, bg_fetch_fn
  end

  -- Step 5: read or write the auto pin. Only fires when the caller opted in
  -- via trust_auto_pin.
  local auto_pin
  if cfg.trust_auto_pin then
    auto_pin = store.get_auto_pin(data, auto_pin_key)
    if auto_pin == nil and candidates[1] then
      auto_pin = candidates[1]
      store.set_auto_pin(data, auto_pin_key, auto_pin)
      local wok, werr = store.write(url, data)
      if not wok then
        warn("store write failed while recording auto_pin: " .. (werr or ""))
        return ZERO_HASH, bg_fetch_fn
      end
    end
  end

  -- Step 6: three-way winner from cooled / auto_pin / trusted_commit.
  local result = picker.pick(candidates, data.fetched_at,
                              cooldown_sec, now, auto_pin, opts.trusted_commit)
  return result or ZERO_HASH, bg_fetch_fn
end

function M.thaw(url_or_opts, opts)
  local result, bg_fetch_fn = thaw_impl(url_or_opts, opts)
  if bg_fetch_fn then
    vim.schedule(bg_fetch_fn)
  end
  return result
end

return M
