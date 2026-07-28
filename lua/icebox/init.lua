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

--- Configure icebox.nvim. Optional. If setup() is never called, thaw() uses
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
-- thaw state; it just translates opts into fetch arguments.
local function fetch_target_for(url, opts)
  if opts.clone_path then
    return { clone_path = opts.clone_path }
  end
  return { cache_dir = store.cache_dir_for(url) }
end

-- ─── thaw() ─────────────────────────────────────────────────────────────────
--
-- Signatures (exactly these three are accepted; any other shape fails):
--   thaw(url_string)
--   thaw(url_string, opts_table)
--   thaw(opts_table)
--
-- Reads the first-observation timestamps stored locally for the commits
-- selected by the URL and range specified in the arguments, and returns
-- the newest cooled commit within that selection. Store refreshes happen
-- in the background, so thaw() resolves against whatever the store held
-- at call time. Two exceptions run a synchronous fetch instead: when the
-- store has not been initialised yet, and when this specific (URL, range)
-- combination is being called for the first time.
--
-- Returns |icebox.ZERO_HASH| on failure. See |icebox.thaw()| in
-- doc/icebox.txt for the full list of accepted opts.
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
    -- when neither branch nor version is specified the sync fetch happens
    -- under the shared "default" identifier because at this point the
    -- caller has not committed to a branch or a version.
    local initial_fetched_key
    if opts.branch then
      initial_fetched_key = "branch:" .. opts.branch
    elseif opts.version then
      initial_fetched_key = "version:" .. opts.version
    else
      initial_fetched_key = "default"
    end

    -- Open the store handle. Blocks (with vim.wait) for up to a few seconds
    -- if another process holds the lock, typically the case when a
    -- concurrent thaw is running its own sync fetch. Timing out here means
    -- we give up on this thaw call; a subsequent call will retry.
    local handle, open_err = store.open(url)
    if not handle then
      warn("store open failed: " .. (open_err or ""))
      return ZERO_HASH
    end

    -- Everything from here on runs inside a pcall so that any error thrown
    -- between store.open and store.close still releases the URL lock. Lua
    -- has no `finally`; this pcall + explicit close below is our stand-in.
    -- `winner` and `sync_fetch_failed` are captured via upvalue so the
    -- outer code can act on them after the guarded block returns.
    local winner
    local sync_fetch_failed = false
    local sync_fetch_err

    local guarded_ok, guarded_err = pcall(function()
      local data = handle.data

      -- Steps 1/2: sync fetch when this range has never been fetched
      -- before. We never enter both branches on the same call:
      -- is_initial_fetched is monotonic and steps 1 and 2 are two names
      -- for the same "first fetch for this range" condition (step 1
      -- covers the fresh-store case because is_initial_fetched(...) is
      -- false on a brand-new empty store).
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
          sync_fetch_failed = true
          sync_fetch_err    = fetch_err
          return
        end

        store.merge(data, new_data)
        store.mark_initial_fetched(data, initial_fetched_key)
        -- When neither branch nor version is specified, the fetch also
        -- fully populates whichever concrete range the default resolves
        -- to. Mark that range as fetched too so a later thaw with
        -- `branch = <default>` does not fire again.
        if initial_fetched_key == "default" then
          if store.has_semver_tags(data) then
            store.mark_initial_fetched(data, "version:>=0.0.0")
          elseif data.default_branch then
            store.mark_initial_fetched(data, "branch:" .. data.default_branch)
          end
        end
        ran_sync_fetch = true
      end

      -- Step 3: arm a bg fetch for after the main body returns. Never
      -- fires when steps 1/2 already ran a sync fetch. The store is
      -- fresh enough. The coroutine body is pcall-guarded so an
      -- unexpected error inside it does not leak the URL lock.
      if not ran_sync_fetch then
        bg_fetch_fn = function()
          coroutine.wrap(function()
            local bg_handle, bg_err = store.open(url)
            if not bg_handle then
              warn("bg store open failed: " .. (bg_err or ""))
              return
            end
            local bg_ok, bg_pcall_err = pcall(function()
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
            end)
            local close_ok, close_err = store.close(bg_handle)
            if not close_ok then
              warn("bg store close failed: " .. (close_err or ""))
            end
            if not bg_ok then
              warn("bg fetch coroutine error: " .. tostring(bg_pcall_err))
            end
          end)()
        end
      end

      -- Step 4: pick the range we resolve against and collect its
      -- candidate set. `opts` is never mutated; when neither branch nor
      -- version is specified, the default range is expressed only via
      -- the local `auto_pin_key` and `candidates` we set here.
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
        return
      end

      -- Step 5: read or write the auto pin. Only fires when the caller
      -- opted in via trust_auto_pin. The pin is written exactly once per
      -- (URL, range). If one already exists we reuse it verbatim.
      local auto_pin
      if cfg.trust_auto_pin then
        auto_pin = store.get_auto_pin(data, auto_pin_key)
        if auto_pin == nil and candidates[1] then
          auto_pin = candidates[1]
          store.set_auto_pin(data, auto_pin_key, auto_pin)
        end
      end

      -- Step 6: three-way winner from cooled / auto_pin / trusted_commit.
      winner = picker.pick(candidates, data.fetched_at,
                            cooldown_sec, now, auto_pin, opts.trusted_commit)
    end)

    -- Flush and release the lock. Runs unconditionally: on the pcall
    -- error path this is the only reason the lock does not leak; on the
    -- normal path this is where sync fetch results actually persist.
    local close_ok, close_err = store.close(handle)

    if not guarded_ok then
      warn("thaw error: " .. tostring(guarded_err))
      return ZERO_HASH
    end
    if sync_fetch_failed then
      warn("sync fetch failed: " .. (sync_fetch_err or "unknown"))
      return ZERO_HASH
    end
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
