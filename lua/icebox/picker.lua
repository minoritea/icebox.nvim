local M = {}

-- Pick a hash from a newest-first candidate array.
--
-- `candidates` is the return value of collector.from_branch / from_version:
-- an array of hashes ordered so that "newer" (branch history-wise or
-- semver-wise) is at a smaller index.
--
-- Selection rule: return the hash whose index is the smallest among
-- {newest cooled commit, trusted_commit} inside the array. If neither
-- appears, return nil. The caller substitutes nil with ZERO_HASH.
--
-- Cooldown is compared per-hash using `fetched_at[hash] + cooldown_sec <= now`.
-- `trusted_commit` bypasses the cooldown gate but still requires membership
-- in the candidate set; a trusted_commit outside `candidates` is ignored.
--
-- Commit-object timestamps are never consulted.
function M.pick(candidates, fetched_at, cooldown_sec, now, trusted_commit)
  local cooled_idx  = nil
  local trusted_idx = nil

  for i, hash in ipairs(candidates) do
    if not cooled_idx then
      local fa = fetched_at[hash]
      if fa and fa + cooldown_sec <= now then
        cooled_idx = i
      end
    end
    if trusted_commit and not trusted_idx and hash == trusted_commit then
      trusted_idx = i
    end
    if cooled_idx and (not trusted_commit or trusted_idx) then
      break
    end
  end

  local winner = cooled_idx
  if trusted_idx and (not winner or trusted_idx < winner) then
    winner = trusted_idx
  end
  return winner and candidates[winner] or nil
end

return M
