local M = {}

local config   = require("icebox.config")
local store    = require("icebox.store")
local git      = require("icebox.git")
local resolver = require("icebox.resolver")
local validate = require("icebox.validate")

-- The zero hash is returned when no cooled commit is available yet.
M.ZERO_HASH = validate.ZERO_HASH
local ZERO_HASH = M.ZERO_HASH

local function warn(msg)
  vim.notify("[icebox] " .. msg, vim.log.levels.WARN)
end

--- Configure icebox.nvim. Optional — if setup() is never called, thaw() uses
--- the built-in defaults (cooldown_days=7, trust_on_first_use=false,
--- branch_commits_per_fetch=500). Per-call overrides on thaw() opts take
--- precedence over both setup values and defaults.
function M.setup(opts)
  config.set(opts or {})
end

-- Build the fetch-opts table for git.fetch_branch_* calls. Always populates
-- exactly one of clone_path (when the caller supplied it) or cache_dir
-- (the icebox-owned bare clone for this URL).
local function fetch_opts_for(url, opts)
  if opts.clone_path then
    return { clone_path = opts.clone_path }
  end
  return { cache_dir = store.cache_dir_for(url) }
end

-- ─── Background fetch ────────────────────────────────────────────────────────

-- Acquire the URL's cross-process lock, invoke `fetch_fn(finish)` where
-- `finish(new_data, err)` merges the fetch result into the store and
-- releases the lock. If the lock is already held by a live process the
-- fetch is skipped entirely.
local function with_store_lock(url, fetch_fn)
  if not store.lock(url) then
    return  -- another process holds the lock for this URL
  end
  fetch_fn(function(new_data, err)
    if err then
      warn("fetch failed for " .. url .. ": " .. err)
      store.unlock(url)
      return
    end
    local data = store.read(url)
    store.merge(data, new_data)
    local ok, write_err = store.write(url, data)
    if not ok then
      warn("store write failed: " .. (write_err or ""))
    end
    store.unlock(url)
  end)
end

-- Background fetch dispatch.
-- Branch path pairs the branch history fetch with an ls-remote so newly-added
-- upstream tags are picked up too — a future fallback can then swap to the
-- version route without waiting for the user to change opts. Version path
-- skips the branch clone entirely (ls-remote is authoritative for tags).
-- The default path (neither branch nor version specified) probes via
-- ls-remote and, if the upstream has no semver tags, follows through with a
-- branch clone against the discovered default_branch — populating the store
-- in a single fetch pass so subsequent thaw calls do not need repeat probes.
local function bg_fetch(url, opts, cfg)
  with_store_lock(url, function(finish)
    if opts.branch then
      git.fetch_branch_and_tags_async(url, opts.branch, cfg.branch_commits_per_fetch,
        fetch_opts_for(url, opts), finish)
    elseif opts.version then
      -- version path ignores clone_path — ls-remote is authoritative.
      git.fetch_tags_async(url, finish)
    else
      git.fetch_default_async(url, fetch_opts_for(url, opts),
        cfg.branch_commits_per_fetch, finish)
    end
  end)
end

-- ─── Resolve logic ───────────────────────────────────────────────────────────

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
function M.thaw(url_or_opts, opts)
  -- Canonicalize the call shape. Exactly three are accepted:
  --   thaw(url)        : url_or_opts is a string, opts is nil
  --   thaw(url, opts)  : url_or_opts is a string, opts is a table
  --   thaw(opts)       : url_or_opts is a table,  opts is nil
  -- Anything else (nil first arg, table+table, string+non-table, etc.)
  -- is a parse error surfaced as WARN + ZERO_HASH.
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

  -- 1. Parse opts first (may contain url / clone_path)
  local parsed_opts, opts_err = validate.opts(opts)
  if not parsed_opts then
    warn(opts_err or "invalid opts")
    return ZERO_HASH
  end
  opts = parsed_opts

  -- 2. Resolve URL. The three sources (url arg, opts.url, opts.clone_path)
  --    are mutually exclusive. Multiple → parse error. None → parse error.
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

  -- 3. Validate the resolved URL
  local url_ok, url_err = validate.url(resolved_url)
  if not url_ok then
    warn("invalid url: " .. (url_err or ""))
    return ZERO_HASH
  end
  url = resolved_url

  -- 4. Resolve effective cfg (per-call overrides win over setup values)
  local cfg = config.merge_overrides({
    cooldown_days            = opts.cooldown_days,
    trust_on_first_use       = opts.trust_on_first_use,
    branch_commits_per_fetch = opts.branch_commits_per_fetch,
  })
  local cooldown_sec = cfg.cooldown_days * 86400
  local now          = os.time()

  -- 5. Load store (shared across all subsequent steps)
  local data = store.read(url)

  -- 6. Resolve default opts if none of branch/version specified.
  --
  -- Conceptually there are two fallback routes:
  --   (a) if the store has semver tags → behave as `version = ">=0.0.0"`
  --   (b) otherwise                    → behave as `branch = <default_branch>`
  -- If the store has neither cached tags nor a cached default_branch yet, we
  -- leave opts untouched so bg_fetch dispatches to fetch_default_async, which
  -- probes upstream and — when no semver tags exist — follows through with a
  -- branch clone against the discovered default_branch in the same pass.
  local resolved_kind = opts.branch or opts.version
  -- default_branch_unknown: branch not specified and not yet cached in store.
  local default_branch_unknown = false
  if not resolved_kind then
    if store.has_semver_tags(data) then
      opts = vim.tbl_extend("keep", opts, { version = ">=0.0.0" })
    elseif data.default_branch then
      opts = vim.tbl_extend("keep", opts, { branch = data.default_branch })
    elseif not cfg.trust_on_first_use then
      -- Empty store, no branch/version, no default_branch: schedule a probe
      -- (ls-remote + fallback branch fetch) and return zero for this call.
      vim.schedule(function() bg_fetch(url, opts, cfg) end)
      return ZERO_HASH
    else
      -- Bootstrap under trust_on_first_use=true: sync fetch with branch=nil
      -- clones the default branch and discovers its name in the process.
      default_branch_unknown = true
    end
  end

  -- 7. Main resolve from store
  if store.has_records(data) then
    local result = resolver.resolve(data, opts, cooldown_sec, now)
    vim.schedule(function() bg_fetch(url, opts, cfg) end)
    return result or ZERO_HASH
  end

  -- 8. fetched_at is empty (first time for this URL)
  if not cfg.trust_on_first_use then
    vim.schedule(function() bg_fetch(url, opts, cfg) end)
    return ZERO_HASH
  end

  -- trust_on_first_use=true
  if opts.trusted_commit then
    vim.schedule(function() bg_fetch(url, opts, cfg) end)
    return opts.trusted_commit
  end

  -- Synchronous fetch
  local new_data, fetch_err
  if opts.branch or default_branch_unknown then
    new_data, fetch_err = git.fetch_branch_sync(url, opts.branch,
      cfg.branch_commits_per_fetch, fetch_opts_for(url, opts))
    if new_data and new_data.default_branch and default_branch_unknown then
      opts.branch = new_data.default_branch
    end
  else
    -- version (clone_path is ignored — ls-remote is authoritative)
    new_data, fetch_err = git.fetch_tags_sync(url)
  end

  if fetch_err or not new_data then
    warn("sync fetch failed: " .. (fetch_err or "unknown"))
    return ZERO_HASH
  end

  -- Merge and persist
  store.merge(data, new_data)
  store.write(url, data)

  -- Return newest match without cooldown filter (trust_on_first_use path).
  -- Reuse resolver with cooldown_sec=0 so all fetched entries are eligible.
  if opts.branch then
    local result = resolver.resolve_branch(data, opts.branch, 0, math.huge)
    if result then return result end
  elseif opts.version then
    local result = resolver.resolve_version(data, opts.version, 0, math.huge, opts.normalize)
    if result then return result end
  end

  return ZERO_HASH
end

return M
