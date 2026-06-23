local M = {}

local semver = require("icebox.semver")

local ZERO_HASH = "0000000000000000000000000000000000000000"

-- Returns the best cooled-down hash for the given opts, or nil if none found.
-- `data`         : store table (fetched_at, branches, tags)
-- `opts`         : validated opts table (one of branch/tag/version/commit set)
-- `cooldown_sec` : number of seconds required since fetched_at
-- `now`          : current unix timestamp
function M.resolve(data, opts, cooldown_sec, now)
  if opts.branch then
    return M._resolve_branch(data, opts.branch, cooldown_sec, now)
  elseif opts.tag then
    return M._resolve_tag(data, opts.tag, cooldown_sec, now)
  elseif opts.version then
    return M._resolve_version(data, opts.version, cooldown_sec, now)
  elseif opts.commit then
    return M._resolve_commit(data, opts.commit, cooldown_sec, now)
  end
  return nil
end

function M._resolve_branch(data, branch, cooldown_sec, now)
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

function M._resolve_tag(data, tag_name, cooldown_sec, now)
  local hash = data.tags and data.tags[tag_name]
  if not hash then return nil end
  local fa = data.fetched_at[hash]
  if fa and fa + cooldown_sec <= now then
    return hash
  end
  return nil
end

function M._resolve_version(data, range_str, cooldown_sec, now)
  local pred, err = semver.parse_range(range_str)
  if not pred then return nil end

  -- Determine whether this repo uses "v"-prefixed tags.
  local has_v_prefix = false
  if data.tags then
    for tag, _ in pairs(data.tags) do
      if tag:sub(1, 1) == "v" and semver.is_semver_tag(tag) then
        has_v_prefix = true
        break
      end
    end
  end

  local best_tag  = nil
  local best_hash = nil

  if data.tags then
    for tag, hash in pairs(data.tags) do
      -- Skip non-semver tags
      if not semver.is_semver_tag(tag) then goto continue end
      -- If repo has v-prefixed tags, skip non-v tags
      if has_v_prefix and tag:sub(1, 1) ~= "v" then goto continue end

      local fa = data.fetched_at[hash]
      if fa and fa + cooldown_sec <= now then
        local ver = tag:gsub("^v", "")
        if pred({ tonumber(ver:match("^(%d+)")),
                  tonumber(ver:match("^%d+%.(%d+)")),
                  tonumber(ver:match("^%d+%.%d+%.(%d+)") or "0") }) then
          if best_tag == nil or semver.gt(tag, best_tag) then
            best_tag  = tag
            best_hash = hash
          end
        end
      end
      ::continue::
    end
  end

  return best_hash
end

function M._resolve_commit(data, hash, cooldown_sec, now)
  local fa = data.fetched_at[hash]
  if fa and fa + cooldown_sec <= now then
    return hash
  end
  return nil
end

-- Apply fallback: return trusted_commit or zero_hash.
function M.fallback(opts)
  return opts.trusted_commit or ZERO_HASH
end

return M
