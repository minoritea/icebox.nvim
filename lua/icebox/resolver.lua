local M = {}

local semver   = require("icebox.semver")
local validate = require("icebox.validate")

-- Returns the best cooled-down hash for the given opts, or nil if none found.
-- `data`         : store table (fetched_at, branches, tags)
-- `opts`         : validated opts table (one of branch/tag/version/commit set)
-- `cooldown_sec` : number of seconds required since fetched_at
-- `now`          : current unix timestamp
function M.resolve(data, opts, cooldown_sec, now)
  if opts.branch then
    return M.resolve_branch(data, opts.branch, cooldown_sec, now)
  elseif opts.tag then
    return M.resolve_tag(data, opts.tag, cooldown_sec, now)
  elseif opts.version then
    return M.resolve_version(data, opts.version, cooldown_sec, now, opts.normalize)
  elseif opts.commit then
    return M.resolve_commit(data, opts.commit, cooldown_sec, now)
  end
  return nil
end

function M.resolve_branch(data, branch, cooldown_sec, now)
  local hashes = data.branches and data.branches[branch]
  if not hashes then return nil end
  for _, hash in ipairs(hashes) do
    local fa = data.fetched_at[hash]
    if fa and fa + cooldown_sec <= now then
      return hash
    end
  end
  return nil
end

function M.resolve_tag(data, tag_name, cooldown_sec, now)
  local hash = data.tags and data.tags[tag_name]
  if not hash then return nil end
  local fa = data.fetched_at[hash]
  if fa and fa + cooldown_sec <= now then
    return hash
  end
  return nil
end

function M.resolve_version(data, range_str, cooldown_sec, now, normalize_fn)
  local pred, err = semver.parse_range(range_str)
  if not pred then return nil end

  normalize_fn = normalize_fn or semver.default_normalize

  local tag_names = {}
  if data.tags then
    for tag, _ in pairs(data.tags) do
      tag_names[#tag_names + 1] = tag
    end
  end

  local entries = normalize_fn(tag_names)

  local best_ver  = nil
  local best_hash = nil

  for tag, version in pairs(entries) do
    local hash = data.tags[tag]
    if not hash then goto continue end
    local fa = data.fetched_at[hash]
    if fa and fa + cooldown_sec <= now then
      if pred(version) then
        if best_ver == nil or semver.gt(tag, best_ver) then
          best_ver  = tag
          best_hash = hash
        end
      end
    end
    ::continue::
  end

  return best_hash
end

function M.resolve_commit(data, hash, cooldown_sec, now)
  local fa = data.fetched_at[hash]
  if fa and fa + cooldown_sec <= now then
    return hash
  end
  return nil
end

-- Apply fallback: return trusted_commit or zero_hash.
function M.fallback(opts)
  return opts.trusted_commit or validate.ZERO_HASH
end

return M
