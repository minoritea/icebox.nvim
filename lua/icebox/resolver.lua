local M = {}

local semver = require("icebox.semver")

-- Resolution model:
--   1. Extract the candidate set of commits from the store based on opts
--      (branch history / version range / single tag / single commit).
--   2. Find the newest cooled-down commit within that set.
--   3. If trusted_commit is set AND trusted_commit is in the candidate set,
--      return whichever of {trusted_commit, newest-cooled} is newer.
--   4. Otherwise return newest-cooled, or nil if none.
-- The caller substitutes nil with ZERO_HASH.

-- Returns the best hash for the given opts, or nil if none found.
-- `data`         : store table (fetched_at, branches, tags)
-- `opts`         : validated opts table (one of branch/tag/version/commit set)
-- `cooldown_sec` : number of seconds required since fetched_at
-- `now`          : current unix timestamp
function M.resolve(data, opts, cooldown_sec, now)
  if opts.branch then
    return M.resolve_branch(data, opts.branch, cooldown_sec, now, opts.trusted_commit)
  elseif opts.tag then
    return M.resolve_tag(data, opts.tag, cooldown_sec, now, opts.trusted_commit)
  elseif opts.version then
    return M.resolve_version(data, opts.version, cooldown_sec, now, opts.normalize, opts.trusted_commit)
  elseif opts.commit then
    return M.resolve_commit(data, opts.commit, cooldown_sec, now, opts.trusted_commit)
  end
  return nil
end

-- Branch: candidate set is data.branches[branch] (newest-first array).
-- "Newer" == smaller array index.
function M.resolve_branch(data, branch, cooldown_sec, now, trusted_commit)
  local hashes = data.branches and data.branches[branch]
  if not hashes then return nil end

  local cooled_idx = nil
  for i, hash in ipairs(hashes) do
    local fa = data.fetched_at[hash]
    if fa and fa + cooldown_sec <= now then
      cooled_idx = i
      break
    end
  end

  local trusted_idx = nil
  if trusted_commit then
    for i, hash in ipairs(hashes) do
      if hash == trusted_commit then
        trusted_idx = i
        break
      end
    end
  end

  if trusted_idx and cooled_idx then
    if trusted_idx <= cooled_idx then
      return trusted_commit
    end
    return hashes[cooled_idx]
  elseif trusted_idx then
    return trusted_commit
  elseif cooled_idx then
    return hashes[cooled_idx]
  end
  return nil
end

-- Tag: candidate set is a single hash. If trusted_commit equals it, they
-- refer to the same commit, so "newer" is trivially either one.
function M.resolve_tag(data, tag_name, cooldown_sec, now, trusted_commit)
  local hash = data.tags and data.tags[tag_name]
  if not hash then return nil end

  if trusted_commit and trusted_commit == hash then
    return trusted_commit
  end

  local fa = data.fetched_at[hash]
  if fa and fa + cooldown_sec <= now then
    return hash
  end
  return nil
end

-- Version range: candidate set is all tags matching the range.
-- "Newer" == higher semver among matched tags. trusted_commit is only in
-- the candidate set if some matching tag points at the same hash.
function M.resolve_version(data, range_str, cooldown_sec, now, normalize_fn, trusted_commit)
  local pred = semver.parse_range(range_str)
  if not pred then return nil end

  normalize_fn = normalize_fn or semver.default_normalize

  local tag_names = {}
  if data.tags then
    for tag, _ in pairs(data.tags) do
      tag_names[#tag_names + 1] = tag
    end
  end

  local entries = normalize_fn(tag_names)

  -- Compare using the version tuple produced by the normalizer, not the tag
  -- string. Custom normalizers may map non-standard tag names (e.g.
  -- "release-1.2.3") that semver.gt can't parse.
  local best_cooled_hash = nil
  local best_cooled_ver  = nil
  local trusted_ver      = nil  -- highest version in range whose hash == trusted_commit

  for tag, version in pairs(entries) do
    local hash = data.tags[tag]
    if hash and pred(version) then
      if trusted_commit and hash == trusted_commit then
        if trusted_ver == nil or semver.cmp_versions(version, trusted_ver) > 0 then
          trusted_ver = version
        end
      end
      local fa = data.fetched_at[hash]
      if fa and fa + cooldown_sec <= now then
        if best_cooled_ver == nil or semver.cmp_versions(version, best_cooled_ver) > 0 then
          best_cooled_ver  = version
          best_cooled_hash = hash
        end
      end
    end
  end

  if trusted_ver and best_cooled_ver then
    if semver.cmp_versions(trusted_ver, best_cooled_ver) >= 0 then
      return trusted_commit
    end
    return best_cooled_hash
  elseif trusted_ver then
    return trusted_commit
  elseif best_cooled_hash then
    return best_cooled_hash
  end
  return nil
end

-- Commit: candidate set is a single hash. Same shape as resolve_tag.
function M.resolve_commit(data, hash, cooldown_sec, now, trusted_commit)
  if trusted_commit and trusted_commit == hash then
    return trusted_commit
  end
  local fa = data.fetched_at[hash]
  if fa and fa + cooldown_sec <= now then
    return hash
  end
  return nil
end

return M
