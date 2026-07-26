local M = {}

-- Pick a hash from a newest-first candidate array.
--
-- `candidates` is the return value of collector.from_branch / from_version:
-- an array of hashes ordered so that "newer" (branch history-wise or
-- semver-wise) is at a smaller index.
--
-- Selection rule: return the hash whose index is the smallest among
-- {newest cooled commit, initial_pin, trusted_commit} inside the array.
-- If none of them appear in `candidates`, return nil. The caller substitutes
-- nil with ZERO_HASH.
--
-- Cooldown is compared per-hash using `fetched_at[hash] + cooldown_sec <= now`.
-- Both `initial_pin` and `trusted_commit` bypass the cooldown gate but still
-- require membership in the candidate set; a bypass hash outside `candidates`
-- is ignored.
--
-- Commit-object timestamps are never consulted.
function M.pick(candidates, fetched_at, cooldown_sec, now, initial_pin, trusted_commit)
  local cooled_idx  = nil
  local pin_idx     = nil
  local trusted_idx = nil

  for i, hash in ipairs(candidates) do
    if not cooled_idx then
      local fa = fetched_at[hash]
      if fa and fa + cooldown_sec <= now then
        cooled_idx = i
      end
    end
    if initial_pin and not pin_idx and hash == initial_pin then
      pin_idx = i
    end
    if trusted_commit and not trusted_idx and hash == trusted_commit then
      trusted_idx = i
    end
    -- Early exit once every candidate we care about has been located.
    if cooled_idx
       and (not initial_pin    or pin_idx)
       and (not trusted_commit or trusted_idx) then
      break
    end
  end

  local winner = cooled_idx
  if pin_idx and (not winner or pin_idx < winner) then
    winner = pin_idx
  end
  if trusted_idx and (not winner or trusted_idx < winner) then
    winner = trusted_idx
  end
  return winner and candidates[winner] or nil
end

return M
