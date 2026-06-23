local M = {}

local config   = require("icebox.config")
local store    = require("icebox.store")
local git      = require("icebox.git")
local resolver = require("icebox.resolver")
local validate = require("icebox.validate")
local semver   = require("icebox.semver")

local ZERO_HASH = "0000000000000000000000000000000000000000"

local function warn(msg)
  vim.notify("[icebox] " .. msg, vim.log.levels.WARN)
end

function M.setup(opts)
  config.set(opts or {})
end

-- ─── Background fetch ────────────────────────────────────────────────────────

local function bg_fetch(url, opts)
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
  end
  -- commit opts: no background fetch
end

-- ─── Resolve logic ───────────────────────────────────────────────────────────

function M.resolve(url, opts)
  -- 1. Validate URL
  local url_ok, url_err = validate.url(url)
  if not url_ok then
    warn("invalid url: " .. (url_err or ""))
    return ZERO_HASH
  end

  -- 2. Parse opts
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
  if not resolved_kind then
    if store.has_semver_tags(data) then
      opts = vim.tbl_extend("keep", opts, { version = ">=0.0.0" })
    else
      if data.default_branch then
        opts = vim.tbl_extend("keep", opts, { branch = data.default_branch })
      else
        -- Need default branch: if trust_on_first_use, the sync fetch below
        -- will clone without --branch and resolve it. Otherwise fetch async.
        if not cfg.trust_on_first_use then
          -- Launch BG fetch which will populate default_branch + tags
          -- Use a temporary sentinel opts to drive fetch_tags_async
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
        -- trust_on_first_use=true: fall through to sync fetch with branch=nil
        -- git.fetch_branch_sync with branch=nil clones default branch
        opts = vim.tbl_extend("keep", opts, { branch = nil, _default_branch_unknown = true })
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

  -- 6. Validate version range (semver.lua)
  if opts.version then
    local _, range_err = semver.parse_range(opts.version)
    if range_err then
      warn("invalid version range: " .. (range_err or ""))
      return ZERO_HASH
    end
  end

  -- 7. Main resolve from store
  if store.has_records(data) then
    local result = resolver.resolve(data, opts, cooldown_sec, now)
    if result then
      vim.schedule(function() bg_fetch(url, opts) end)
      return result
    end
    vim.schedule(function() bg_fetch(url, opts) end)
    return resolver.fallback(opts)
  end

  -- 8. fetched_at is empty (first time for this URL)
  if not cfg.trust_on_first_use then
    vim.schedule(function() bg_fetch(url, opts) end)
    return ZERO_HASH
  end

  -- trust_on_first_use=true
  if opts.trusted_commit then
    vim.schedule(function() bg_fetch(url, opts) end)
    return opts.trusted_commit
  end

  -- Synchronous fetch
  local new_data, fetch_err
  if opts.branch or opts._default_branch_unknown then
    new_data, fetch_err = git.fetch_branch_sync(url, opts.branch)
    if new_data and new_data.default_branch and opts._default_branch_unknown then
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

  -- Return newest match (no cooldown filter for trust_on_first_use)
  if opts.branch then
    local hashes = data.branches and data.branches[opts.branch]
    if hashes and hashes[1] then return hashes[1] end
  elseif opts.version then
    -- find highest semver tag regardless of cooldown
    local has_v = false
    for tag, _ in pairs(data.tags) do
      if tag:sub(1,1) == "v" and semver.is_semver_tag(tag) then has_v = true; break end
    end
    local pred = semver.parse_range(opts.version)
    local best_tag, best_hash = nil, nil
    for tag, hash in pairs(data.tags) do
      if semver.is_semver_tag(tag) then
        if has_v and tag:sub(1,1) ~= "v" then goto skip end
        if pred and pred({ tonumber(tag:gsub("^v",""):match("^(%d+)")),
                           tonumber(tag:gsub("^v",""):match("^%d+%.(%d+)")),
                           tonumber(tag:gsub("^v",""):match("^%d+%.%d+%.(%d+)") or "0") }) then
          if best_tag == nil or semver.gt(tag, best_tag) then
            best_tag = tag; best_hash = hash
          end
        end
      end
      ::skip::
    end
    if best_hash then return best_hash end
  elseif opts.tag then
    local hash = data.tags and data.tags[opts.tag]
    if hash then return hash end
  end

  return ZERO_HASH
end

return M
