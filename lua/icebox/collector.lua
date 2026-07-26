local M = {}

local semver = require("icebox.semver")

-- Return the newest-first branch history array for `branch`, or an empty
-- array when the branch has no cached history. The store already keeps
-- data.branches[branch] in newest-first order, so this is a pass-through.
function M.from_branch(data, branch)
  local hashes = data.branches and data.branches[branch]
  if not hashes then return {} end
  return hashes
end

-- Return the candidate hashes for a version range, ordered by semver
-- descending (highest version first).
--
-- Tags whose normalized version falls inside the range become candidates.
-- The candidate array is deduplicated by hash: when several tags point at
-- the same commit, that commit appears once and is ranked by the highest
-- semver among its tags. `pick` can then compare by array index without
-- needing to reconsult the version tuple.
function M.from_version(data, range_str, normalize_fn)
  local pred = semver.parse_range(range_str)
  if not pred then return {} end
  normalize_fn = normalize_fn or semver.default_normalize

  local tag_names = {}
  if data.tags then
    for tag, _ in pairs(data.tags) do
      tag_names[#tag_names + 1] = tag
    end
  end
  local entries = normalize_fn(tag_names)

  local best = {}  -- hash → highest matching version tuple
  for tag, version in pairs(entries) do
    local hash = data.tags[tag]
    if hash and pred(version) then
      if not best[hash] or semver.cmp_versions(version, best[hash]) > 0 then
        best[hash] = version
      end
    end
  end

  local arr = {}
  for hash, ver in pairs(best) do
    arr[#arr + 1] = { hash = hash, ver = ver }
  end
  table.sort(arr, function(a, b)
    return semver.cmp_versions(a.ver, b.ver) > 0
  end)

  local result = {}
  for _, e in ipairs(arr) do
    result[#result + 1] = e.hash
  end
  return result
end

return M
