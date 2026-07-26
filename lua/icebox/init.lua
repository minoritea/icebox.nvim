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
--- the built-in defaults (cooldown_days=7, trust_initial_pin=false,
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

-- Pin key produced from a validated opts table. Returns nil when the caller
-- supplied neither branch nor version (the fallback route lives under a
-- constant "default" identifier used for initial_fetched only).
local function pin_key_for_opts(opts)
  if opts.branch then
    return "branch:" .. opts.branch
  elseif opts.version then
    return "version:" .. opts.version
  end
  return nil
end

-- Identifier used to track whether the "no branch/version specified" route
-- has ever completed a successful sync fetch. Reserved key — must never
-- collide with legitimate branch/version pin keys (they always include ":").
local DEFAULT_PIN_KEY = "default"

-- ─── Fetch dispatch ─────────────────────────────────────────────────────────
--
-- The three fetch shapes are unified: given the caller's opts, pick which
-- pipeline to run and hand back the raw new_data (or nil + err). The sync/
-- async wrappers below share this dispatch table so callers never branch on
-- opts.branch/opts.version themselves.

local function run_fetch_sync(url, opts, cfg)
  if opts.branch then
    return git.fetch_branch_sync(url, opts.branch,
      cfg.branch_commits_per_fetch, fetch_opts_for(url, opts))
  elseif opts.version then
    return git.fetch_tags_sync(url)
  end
  return git.fetch_default_sync(url, fetch_opts_for(url, opts),
    cfg.branch_commits_per_fetch)
end

local function run_fetch_async(url, opts, cfg, on_done)
  if opts.branch then
    git.fetch_branch_async(url, opts.branch,
      cfg.branch_commits_per_fetch, fetch_opts_for(url, opts), on_done)
  elseif opts.version then
    git.fetch_tags_async(url, on_done)
  else
    git.fetch_default_async(url, fetch_opts_for(url, opts),
      cfg.branch_commits_per_fetch, on_done)
  end
end

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
    local data, read_err = store.read(url)
    if not data then
      warn("store read failed: " .. (read_err or ""))
      store.unlock(url)
      return
    end
    store.merge(data, new_data)
    local ok, write_err = store.write(url, data)
    if not ok then
      warn("store write failed: " .. (write_err or ""))
    end
    store.unlock(url)
  end)
end

-- Background fetch: same three-way dispatch as the sync path, minus the
-- initial_fetched bookkeeping (async fetches never advance that flag —
-- only the sync path can, so an async retry after a sync failure still
-- triggers a fresh sync attempt on the next thaw call).
local function bg_fetch(url, opts, cfg)
  with_store_lock(url, function(finish)
    run_fetch_async(url, opts, cfg, finish)
  end)
end

-- ─── Sync fetch driver used by steps 1 & 2 ──────────────────────────────────
--
-- Runs the appropriate fetch pipeline synchronously, merges the result into
-- `data`, and marks initial_fetched for both the fetch identifier (the pin
-- key of whatever branch/version was requested, or DEFAULT_PIN_KEY when the
-- caller left it up to the fallback) *and* — for the fallback route — the
-- pin key that the fetch result actually resolves to. Marking both avoids a
-- redundant second sync fetch on the very next step for the fallback route.
--
-- Returns true on success, or nil + err on failure. On failure the store is
-- neither merged nor persisted, so a later thaw call will retry the same
-- sync fetch.
local function run_sync_fetch_and_persist(url, opts, cfg, data, fetch_key)
  local new_data, fetch_err = run_fetch_sync(url, opts, cfg)
  if not new_data then
    return nil, fetch_err or "unknown fetch error"
  end

  store.merge(data, new_data)
  store.mark_initial_fetched(data, fetch_key)

  -- When we ran under the fallback route, the fetch result also fully
  -- populates whichever route (branch / version) the fallback ends up
  -- choosing. Mark that route as fetched too so step 2 does not fire a
  -- second, effectively-duplicate sync fetch on the next call.
  if fetch_key == DEFAULT_PIN_KEY then
    if store.has_semver_tags(data) then
      store.mark_initial_fetched(data, "version:>=0.0.0")
    elseif data.default_branch then
      store.mark_initial_fetched(data, "branch:" .. data.default_branch)
    end
  end

  local ok, write_err = store.write(url, data)
  if not ok then
    return nil, write_err or "store write failed"
  end
  return true
end

-- ─── Fallback resolution (step 4) ───────────────────────────────────────────
--
-- With the store populated, decide which route to resolve from. When the
-- caller pinned branch/version we honour that verbatim; otherwise we look
-- at what the store has and pick version if any semver tags exist, else
-- fall back to the cached default_branch. `opts` is never mutated — the
-- selected route is returned as a fresh table so callers can reuse the
-- original opts for other purposes if they need to.
--
-- Returns { branch = ... } or { version = ... } on success, or nil + err
-- when neither route can be resolved (upstream has no tags and no known
-- default branch).
local function resolved_route(data, opts)
  if opts.branch then
    return { branch = opts.branch }
  end
  if opts.version then
    return { version = opts.version }
  end
  if store.has_semver_tags(data) then
    return { version = ">=0.0.0" }
  end
  if data.default_branch then
    return { branch = data.default_branch }
  end
  return nil, "upstream has neither semver tags nor a known default branch"
end

local function pin_key_for_route(route)
  if route.branch then
    return "branch:" .. route.branch
  end
  return "version:" .. route.version
end

local function collect_for_route(data, route, opts)
  if route.branch then
    return collector.from_branch(data, route.branch)
  end
  return collector.from_version(data, route.version, opts.normalize)
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
-- Resolution proceeds in six steps once the URL / opts / cfg are settled:
--   1. Sync fetch when the store file does not exist yet.
--   2. Sync fetch when the store is populated but initial_fetched has not
--      been recorded for the requested route (or DEFAULT_PIN_KEY when the
--      caller left branch/version unset).
--   3. Schedule a bg_fetch only when neither step 1 nor 2 ran a sync fetch.
--   4. Collect the candidate set for the resolved route (fallback picks the
--      version-or-branch route based on the current store contents).
--   5. When trust_initial_pin is on, materialise / read initial_pin.
--   6. Delegate to picker.pick for the 3-way winner (cooled / initial_pin /
--      trusted_commit).
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
    trust_initial_pin        = opts.trust_initial_pin,
    branch_commits_per_fetch = opts.branch_commits_per_fetch,
  })
  local cooldown_sec = cfg.cooldown_days * 86400
  local now          = os.time()

  -- Identifier used for the initial_fetched flag on this call. Independent of
  -- the pin key that step 4 eventually resolves to: for the fallback route
  -- the sync fetch happens under the shared "default" identifier because at
  -- this point the caller has not committed to a branch or a version.
  local fetch_key = pin_key_for_opts(opts) or DEFAULT_PIN_KEY

  local ran_sync_fetch = false

  -- Step 1: store file does not exist yet → run the sync fetch that matches
  -- opts (branch / version / fallback). Failure returns immediately without
  -- marking initial_fetched, so a later thaw call retries.
  if not store.exists(url) then
    local data = store.read(url)  -- returns an empty template
    if not data then
      warn("store read failed unexpectedly for a non-existent path")
      return ZERO_HASH
    end
    local ok, err = run_sync_fetch_and_persist(url, opts, cfg, data, fetch_key)
    if not ok then
      warn("sync fetch failed: " .. (err or "unknown"))
      return ZERO_HASH
    end
    ran_sync_fetch = true
  end

  -- Load the store for the remainder of the pipeline.
  local data, read_err = store.read(url)
  if not data then
    warn("store read failed: " .. (read_err or ""))
    return ZERO_HASH
  end

  -- Step 2: sync fetch again when the store exists but the requested route
  -- has not been fetched yet. Skipped when step 1 already ran (a fresh store
  -- has just been populated for this call's fetch_key).
  if not ran_sync_fetch and not store.is_initial_fetched(data, fetch_key) then
    local ok, err = run_sync_fetch_and_persist(url, opts, cfg, data, fetch_key)
    if not ok then
      warn("sync fetch failed: " .. (err or "unknown"))
      return ZERO_HASH
    end
    ran_sync_fetch = true
  end

  -- Step 3: schedule a background refresh only if we skipped the sync fetch.
  -- Fires at the tail of thaw() regardless of whether later steps succeed —
  -- the goal is to keep the store fresh, not to block on the result.
  if not ran_sync_fetch then
    vim.schedule(function() bg_fetch(url, opts, cfg) end)
  end

  -- Step 4: pick the route we resolve against, collect its candidate set.
  local route, route_err = resolved_route(data, opts)
  if not route then
    warn(route_err or "no resolvable route")
    return ZERO_HASH
  end
  local pin_key    = pin_key_for_route(route)
  local candidates = collect_for_route(data, route, opts)

  -- Step 5: initial_pin bookkeeping. Only fires when the caller opted in via
  -- trust_initial_pin; independent from the sync-fetch flag in step 1/2.
  local initial_pin
  if cfg.trust_initial_pin then
    initial_pin = store.get_initial_pin(data, pin_key)
    if initial_pin == nil and candidates[1] then
      initial_pin = candidates[1]
      store.set_initial_pin(data, pin_key, initial_pin)
      local ok, write_err = store.write(url, data)
      if not ok then
        warn("store write failed while recording initial_pin: " .. (write_err or ""))
        -- The pin is still usable for this call even if the write failed.
      end
    end
  end

  -- Step 6: three-way winner from cooled / initial_pin / trusted_commit.
  local result = picker.pick(candidates, data.fetched_at,
                              cooldown_sec, now, initial_pin, opts.trusted_commit)
  return result or ZERO_HASH
end

return M
