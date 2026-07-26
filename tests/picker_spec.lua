local h      = require("helpers")
local picker = require("icebox.picker")

local HASH_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local HASH_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local HASH_C = "cccccccccccccccccccccccccccccccccccccccc"
local HASH_D = "dddddddddddddddddddddddddddddddddddddddd"

local NOW          = 1700000000
local COOLDOWN_SEC = 7 * 86400
local OLD          = NOW - COOLDOWN_SEC - 1  -- cooled
local RECENT       = NOW - 3600              -- not cooled

-- pick operates on the newest-first candidate array + a fetched_at map.
-- It knows nothing about branch/version — it just walks the array and picks
-- the smallest index among cooled-newest, initial_pin, and trusted_commit.

h.suite("picker.pick: newest cooled among mixed cooled/uncooled")
do
  local fetched_at = { [HASH_A] = OLD, [HASH_B] = RECENT }
  local candidates = { HASH_B, HASH_A }  -- newest-first
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, nil, nil)
  h.eq(got, HASH_A, "returns newest cooled commit")
end

h.suite("picker.pick: newest when all cooled")
do
  local fetched_at = { [HASH_A] = OLD, [HASH_B] = OLD }
  local candidates = { HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, nil, nil)
  h.eq(got, HASH_B, "returns newest when both cooled")
end

h.suite("picker.pick: nil when nothing cooled and no bypass")
do
  local fetched_at = { [HASH_A] = RECENT }
  local candidates = { HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, nil, nil)
  h.is_nil(got, "nil when nothing cooled and no bypass")
end

h.suite("picker.pick: trusted_commit newer than newest cooled wins")
do
  -- HASH_C (index 1) is trusted; HASH_A (index 3) is cooled. Smaller index wins.
  local fetched_at = { [HASH_A] = OLD, [HASH_B] = RECENT, [HASH_C] = RECENT }
  local candidates = { HASH_C, HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, nil, HASH_C)
  h.eq(got, HASH_C, "trusted_commit at smaller index wins")
end

h.suite("picker.pick: newest cooled wins over older trusted_commit")
do
  -- HASH_A (index 3) is trusted; HASH_C (index 1) is cooled and newer. Cooled wins.
  local fetched_at = { [HASH_A] = OLD, [HASH_B] = OLD, [HASH_C] = OLD }
  local candidates = { HASH_C, HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, nil, HASH_A)
  h.eq(got, HASH_C, "newest cooled preferred when trusted_commit is older")
end

h.suite("picker.pick: trusted_commit off-array is ignored")
do
  -- HASH_D is not in candidates; only cooled candidates count.
  local fetched_at = { [HASH_A] = OLD, [HASH_B] = RECENT }
  local candidates = { HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, nil, HASH_D)
  h.eq(got, HASH_A, "trusted_commit outside candidates is ignored")
end

h.suite("picker.pick: nil when trusted_commit off-array and nothing cooled")
do
  local fetched_at = { [HASH_A] = RECENT }
  local candidates = { HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, nil, HASH_D)
  h.is_nil(got, "nil when neither cooled nor trusted in-array")
end

h.suite("picker.pick: trusted_commit rescues when nothing cooled")
do
  -- Nothing cooled, but trusted_commit is in the candidate array → return it.
  local fetched_at = { [HASH_A] = RECENT, [HASH_B] = RECENT }
  local candidates = { HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, nil, HASH_A)
  h.eq(got, HASH_A, "trusted_commit returned when nothing cooled")
end

h.suite("picker.pick: fetched_at missing is treated as uncooled")
do
  -- HASH_A has no fetched_at entry at all — must NOT be treated as cooled.
  local fetched_at = { [HASH_B] = OLD }
  local candidates = { HASH_A, HASH_B }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, nil, nil)
  h.eq(got, HASH_B, "missing fetched_at excludes candidate from cooled set")
end

h.suite("picker.pick: empty candidates → nil")
do
  local got = picker.pick({}, {}, COOLDOWN_SEC, NOW, HASH_A, HASH_A)
  h.is_nil(got, "empty candidates → nil regardless of bypass hashes")
end

-- ─── initial_pin bypass cases ───────────────────────────────────────────────

h.suite("picker.pick: initial_pin alone rescues when nothing cooled")
do
  local fetched_at = { [HASH_A] = RECENT, [HASH_B] = RECENT }
  local candidates = { HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, HASH_A, nil)
  h.eq(got, HASH_A, "initial_pin returned when nothing cooled")
end

h.suite("picker.pick: initial_pin off-array is ignored")
do
  local fetched_at = { [HASH_A] = OLD, [HASH_B] = RECENT }
  local candidates = { HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, HASH_D, nil)
  h.eq(got, HASH_A, "initial_pin outside candidates is ignored")
end

h.suite("picker.pick: initial_pin newer than cooled wins")
do
  -- initial_pin = HASH_B (index 1) beats cooled HASH_A (index 2).
  local fetched_at = { [HASH_A] = OLD, [HASH_B] = RECENT }
  local candidates = { HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, HASH_B, nil)
  h.eq(got, HASH_B, "initial_pin at smaller index wins over cooled")
end

h.suite("picker.pick: newest cooled beats older initial_pin")
do
  -- Both cooled but initial_pin is at index 2 (older); newest cooled wins.
  local fetched_at = { [HASH_A] = OLD, [HASH_B] = OLD }
  local candidates = { HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, HASH_A, nil)
  h.eq(got, HASH_B, "newest cooled preferred when initial_pin is older")
end

h.suite("picker.pick: three-way — initial_pin, trusted_commit, cooled")
do
  -- HASH_A (index 3, cooled), HASH_B (index 2, initial_pin), HASH_C (index 1, trusted)
  -- Smallest index (HASH_C) wins.
  local fetched_at = { [HASH_A] = OLD, [HASH_B] = RECENT, [HASH_C] = RECENT }
  local candidates = { HASH_C, HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, HASH_B, HASH_C)
  h.eq(got, HASH_C, "smallest-index candidate wins across all three bypass sources")
end

h.suite("picker.pick: three-way with cooled at smallest index")
do
  -- HASH_C at index 1 is cooled, HASH_B at index 2 is pin, HASH_A at index 3 is trusted.
  local fetched_at = { [HASH_A] = OLD, [HASH_B] = RECENT, [HASH_C] = OLD }
  local candidates = { HASH_C, HASH_B, HASH_A }
  local got = picker.pick(candidates, fetched_at, COOLDOWN_SEC, NOW, HASH_B, HASH_A)
  h.eq(got, HASH_C, "cooled newest wins when it holds the smallest index")
end

h.summary()
