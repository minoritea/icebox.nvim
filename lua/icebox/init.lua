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

--- Configure icebox.nvim. Call once during startup (e.g. in lazy.nvim's config).
--- Defaults apply if setup() is never called:
---   cooldown_days      = 7      (0 disables cooldown)
---   trust_on_first_use = false
--- setup() may be called multiple times; later calls override earlier ones.
function M.setup(opts)
  config.set(opts or {})
end

-- ─── Background fetch ────────────────────────────────────────────────────────

local function bg_fetch(url, opts, default_branch_unknown)
  if not store.lock(url) then
    return  -- another process holds the lock for this URL
  end

  local function finish(new_data, err)
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
  end

  if opts.branch then
    git.fetch_branch_async(url, opts.branch, finish)
  elseif opts.tag or opts.version then
    git.fetch_tags_async(url, finish)
  elseif default_branch_unknown then
    git.fetch_branch_async(url, nil, finish)
  end
  -- commit opts: no background fetch
end

-- ─── Resolve logic ───────────────────────────────────────────────────────────

-- Expand a GitHub shorthand ("owner/repo") into a full HTTPS URL. Leaves any
-- string that already looks like a URL (has a scheme or ssh shorthand) untouched.
local function expand_github_shorthand(url)
  if type(url) ~= "string" then return url end
  if url:find("://", 1, true) then return url end
  if url:match("^[a-zA-Z0-9_.%-]+@[a-zA-Z0-9_.%-]+:.+") then return url end
  local owner, repo = url:match("^([a-zA-Z0-9._%-]+)/([a-zA-Z0-9._%-]+)$")
  if owner and repo then
    return "https://github.com/" .. owner .. "/" .. repo .. ".git"
  end
  return url
end

function M.thaw(url, opts)
  -- 1. Validate URL (GitHub shorthand "owner/repo" is expanded first)
  url = expand_github_shorthand(url)
  local url_ok, url_err = validate.url(url)
  if not url_ok then
    warn("invalid url: " .. (url_err or ""))
    return ZERO_HASH
  end

  -- 2. Parse opts (version range validated inside validate.opts)
  local parsed_opts, opts_err = validate.opts(opts)
  if not parsed_opts then
    warn(opts_err or "invalid opts")
    return ZERO_HASH
  end
  opts = parsed_opts

  local cfg          = config.get()
  local cooldown_sec = cfg.cooldown_days * 86400
  local now          = os.time()

  -- 3. Load store (shared across all subsequent steps)
  local data = store.read(url)

  -- 4. Resolve default opts if none of branch/tag/version/commit specified
  local resolved_kind = opts.branch or opts.tag or opts.version or opts.commit
  -- default_branch_unknown: branch not specified and not yet cached in store.
  -- Kept as a local so it never leaks into the opts table.
  local default_branch_unknown = false
  if not resolved_kind then
    if store.has_semver_tags(data) then
      opts = vim.tbl_extend("keep", opts, { version = ">=0.0.0" })
    else
      if data.default_branch then
        opts = vim.tbl_extend("keep", opts, { branch = data.default_branch })
      else
        if not cfg.trust_on_first_use then
          -- Launch BG fetch which will populate default_branch + tags
          vim.schedule(function()
            if not store.lock(url) then return end
            git.fetch_tags_async(url, function(new_data, err)
              if err then
                warn("fetch failed for " .. url .. ": " .. err)
                store.unlock(url)
                return
              end
              local d = store.read(url)
              store.merge(d, new_data)
              local ok, werr = store.write(url, d)
              if not ok then warn("store write failed: " .. (werr or "")) end
              store.unlock(url)
            end)
          end)
          return ZERO_HASH
        end
        -- trust_on_first_use=true: sync fetch with branch=nil clones default branch
        default_branch_unknown = true
      end
    end
  end

  -- 5. commit: special synchronous handling
  if opts.commit then
    local hash = opts.commit
    if not data.fetched_at[hash] then
      data.fetched_at[hash] = now
      store.write(url, data)
    end
    local result = resolver.resolve(data, opts, cooldown_sec, now)
    return result or resolver.fallback(opts)
  end

  -- 6. Main resolve from store
  if store.has_records(data) then
    local result = resolver.resolve(data, opts, cooldown_sec, now)
    if result then
      vim.schedule(function() bg_fetch(url, opts, default_branch_unknown) end)
      return result
    end
    vim.schedule(function() bg_fetch(url, opts, default_branch_unknown) end)
    return resolver.fallback(opts)
  end

  -- 7. fetched_at is empty (first time for this URL)
  if not cfg.trust_on_first_use then
    vim.schedule(function() bg_fetch(url, opts, default_branch_unknown) end)
    return ZERO_HASH
  end

  -- trust_on_first_use=true
  if opts.trusted_commit then
    vim.schedule(function() bg_fetch(url, opts, default_branch_unknown) end)
    return opts.trusted_commit
  end

  -- Synchronous fetch
  local new_data, fetch_err
  if opts.branch or default_branch_unknown then
    new_data, fetch_err = git.fetch_branch_sync(url, opts.branch)
    if new_data and new_data.default_branch and default_branch_unknown then
      opts.branch = new_data.default_branch
    end
  else
    -- tag or version
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
  elseif opts.tag then
    local result = resolver.resolve_tag(data, opts.tag, 0, math.huge)
    if result then return result end
  end

  return ZERO_HASH
end

return M
