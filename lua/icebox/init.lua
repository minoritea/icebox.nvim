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

-- Build the fetch_target table passed to git.fetch_*_sync calls. Wraps the
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
--   1. Sync fetch when the store did not have this route recorded and the
--      route (branch/version/fallback) has just come into scope for the
--      first time — that is, "store was previously empty" collapses into
--      the same "first fetch for this route" branch as step 2 below.
--   2. Sync fetch when the store exists but this route has not been fetched.
--   3. Otherwise queue a bg fetch to fire after every other step, whether
--      or not those steps succeed.
--   4. Collect the candidate set for the resolved route.
--   5. When trust_auto_pin is on, record or read the auto pin (per (URL,
--      route), written exactly once on the first thaw call where the pin
--      is missing).
--   6. Delegate to picker.pick for the 3-way winner (cooled / auto_pin /
--      trusted_commit).
--
-- The store handle acquired in the middle of thaw() covers steps 1–5:
-- every read and mutation targets in-memory state, and close() flushes
-- once at the end. A bg fetch scheduled by step 3 opens its own handle
-- from a coroutine after thaw() has already returned to the caller.
function M.thaw(url_or_opts, opts)
  local bg_fetch_fn  -- set by step 3; scheduled after the main body returns

  local result = (function()
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
      return ZERO_HASH
    end

    -- Parse opts first (may contain url / clone_path).
    local parsed_opts, opts_err = validate.opts(opts)
    if not parsed_opts then
      warn(opts_err or "invalid opts")
      return ZERO_HASH
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
      return ZERO_HASH
    end
    if #sources == 0 then
      warn("no URL provided: pass a URL string, opts.url, or opts.clone_path")
      return ZERO_HASH
    end

    local resolved_url
    if opts.clone_path then
      local origin, origin_err = git.origin_url(opts.clone_path)
      if not origin then
        warn("clone_path: " .. (origin_err or ""))
        return ZERO_HASH
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
      return ZERO_HASH
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

    -- Identifier used to decide whether steps 1/2 have to run a sync fetch.
    -- Independent of the auto pin key that step 4 eventually settles on:
    -- for the fallback route the sync fetch happens under the shared
    -- "default" identifier because at this point the caller has not
    -- committed to a branch or a version.
    local initial_fetched_key
    if opts.branch then
      initial_fetched_key = "branch:" .. opts.branch
    elseif opts.version then
      initial_fetched_key = "version:" .. opts.version
    else
      initial_fetched_key = "default"
    end

    -- Open the store handle. Blocks (with vim.wait) for up to a few seconds
    -- if another process holds the lock — typically the case when a
    -- concurrent thaw is running its own sync fetch. Timing out here means
    -- we give up on this thaw call; a subsequent call will retry.
    local handle, open_err = store.open(url)
    if not handle then
      warn("store open failed: " .. (open_err or ""))
      return ZERO_HASH
    end

    -- All state mutations from here on target handle.data. close() below
    -- flushes to disk and releases the lock.
    local data = handle.data

    -- Steps 1/2: sync fetch when this route has never been fetched before.
    -- We never enter both branches on the same call — is_initial_fetched
    -- is monotonic and steps 1 and 2 are two names for the same "first
    -- fetch for this route" condition (step 1 covers the fresh-store case
    -- because is_initial_fetched(...) is false on a brand-new empty store).
    local ran_sync_fetch = false
    if not store.is_initial_fetched(data, initial_fetched_key) then
      local new_data, fetch_err
      if opts.branch then
        new_data, fetch_err = git.fetch_branch_sync(url, opts.branch,
          cfg.branch_commits_per_fetch, fetch_target_for(url, opts))
      elseif opts.version then
        new_data, fetch_err = git.fetch_tags_sync(url)
      else
        new_data, fetch_err = git.fetch_default_sync(url,
          cfg.branch_commits_per_fetch, fetch_target_for(url, opts))
      end
      if not new_data then
        store.close(handle)
        warn("sync fetch failed: " .. (fetch_err or "unknown"))
        return ZERO_HASH
      end

      store.merge(data, new_data)
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
      ran_sync_fetch = true
    end

    -- Step 3: arm a bg fetch for after the main body returns. Never fires
    -- when steps 1/2 already ran a sync fetch — the store is fresh enough.
    if not ran_sync_fetch then
      bg_fetch_fn = function()
        coroutine.wrap(function()
          local bg_handle, bg_err = store.open(url)
          if not bg_handle then
            warn("bg store open failed: " .. (bg_err or ""))
            return
          end
          local new_data, fetch_err
          if opts.branch then
            new_data, fetch_err = git.fetch_branch_sync(url, opts.branch,
              cfg.branch_commits_per_fetch, fetch_target_for(url, opts))
          elseif opts.version then
            new_data, fetch_err = git.fetch_tags_sync(url)
          else
            new_data, fetch_err = git.fetch_default_sync(url,
              cfg.branch_commits_per_fetch, fetch_target_for(url, opts))
          end
          if new_data then
            store.merge(bg_handle.data, new_data)
          else
            warn("bg fetch failed: " .. (fetch_err or "unknown"))
          end
          local close_ok, close_err = store.close(bg_handle)
          if not close_ok then
            warn("bg store close failed: " .. (close_err or ""))
          end
        end)()
      end
    end

    -- Step 4: pick the route we resolve against and collect its candidate
    -- set. `opts` is never mutated; the fallback route is only expressed
    -- via the local `auto_pin_key` and `candidates` we set here.
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
      store.close(handle)
      warn("upstream has neither semver tags nor a known default branch")
      return ZERO_HASH
    end

    -- Step 5: read or write the auto pin. Only fires when the caller opted
    -- in via trust_auto_pin. The pin is written exactly once per (URL,
    -- route) — if one already exists we reuse it verbatim.
    local auto_pin
    if cfg.trust_auto_pin then
      auto_pin = store.get_auto_pin(data, auto_pin_key)
      if auto_pin == nil and candidates[1] then
        auto_pin = candidates[1]
        store.set_auto_pin(data, auto_pin_key, auto_pin)
      end
    end

    -- Step 6: three-way winner from cooled / auto_pin / trusted_commit.
    local winner = picker.pick(candidates, data.fetched_at,
                                cooldown_sec, now, auto_pin, opts.trusted_commit)

    -- Flush and release the lock. Any error here surfaces as ZERO_HASH so
    -- callers do not silently trust a hash that never made it to disk.
    local close_ok, close_err = store.close(handle)
    if not close_ok then
      warn("store close failed: " .. (close_err or ""))
      return ZERO_HASH
    end

    return winner or ZERO_HASH
  end)()

  if bg_fetch_fn then
    vim.schedule(bg_fetch_fn)
  end
  return result
end

return M
