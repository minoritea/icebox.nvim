local h         = require("helpers")
local collector = require("icebox.collector")

local HASH_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local HASH_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local HASH_C = "cccccccccccccccccccccccccccccccccccccccc"

-- ─── from_branch ────────────────────────────────────────────────────────────

h.suite("collector.from_branch: returns branches[branch] as-is")
do
  local data = {
    fetched_at = {},
    branches   = { main = { HASH_C, HASH_B, HASH_A } },
    tags       = {},
  }
  local got = collector.from_branch(data, "main")
  h.eq(#got, 3,               "three candidates")
  h.eq(got[1], HASH_C,        "newest at index 1")
  h.eq(got[2], HASH_B,        "middle at index 2")
  h.eq(got[3], HASH_A,        "oldest at index 3")
end

h.suite("collector.from_branch: unknown branch returns empty array")
do
  local data = { fetched_at = {}, branches = { main = { HASH_A } }, tags = {} }
  local got = collector.from_branch(data, "develop")
  h.eq(#got, 0, "empty when branch not in store")
end

h.suite("collector.from_branch: missing branches table returns empty array")
do
  local data = { fetched_at = {}, tags = {} }  -- no branches key at all
  local got = collector.from_branch(data, "main")
  h.eq(#got, 0, "empty when branches key is absent")
end

-- ─── from_version ───────────────────────────────────────────────────────────

h.suite("collector.from_version: tags in range sorted highest-first")
do
  local data = {
    fetched_at = {},
    branches   = {},
    tags       = {
      ["v1.0.0"] = HASH_A,
      ["v1.2.0"] = HASH_B,
      ["v1.3.0"] = HASH_C,
    },
  }
  local got = collector.from_version(data, "^1.0.0")
  h.eq(#got, 3,               "three candidates in range")
  h.eq(got[1], HASH_C,        "v1.3.0 first (highest)")
  h.eq(got[2], HASH_B,        "v1.2.0 second")
  h.eq(got[3], HASH_A,        "v1.0.0 last")
end

h.suite("collector.from_version: tags outside range are excluded")
do
  local data = {
    fetched_at = {},
    branches   = {},
    tags       = {
      ["v1.0.0"] = HASH_A,
      ["v2.0.0"] = HASH_B,  -- outside ^1.0.0
    },
  }
  local got = collector.from_version(data, "^1.0.0")
  h.eq(#got, 1,              "only v1.0.0 in range")
  h.eq(got[1], HASH_A,       "returns HASH_A")
end

h.suite("collector.from_version: v-prefix priority")
do
  -- default_normalize excludes non-v tags when any v-prefixed tag exists.
  local data = {
    fetched_at = {},
    branches   = {},
    tags       = {
      ["v1.0.0"] = HASH_A,
      ["1.0.1"]  = HASH_B,  -- no v prefix, should be ignored
    },
  }
  local got = collector.from_version(data, ">=0.0.0")
  h.eq(#got, 1,              "only v-prefixed tag kept")
  h.eq(got[1], HASH_A,       "HASH_A returned")
end

h.suite("collector.from_version: release ranked higher than pre-release")
do
  local data = {
    fetched_at = {},
    branches   = {},
    tags       = {
      ["v1.2.3-alpha"] = HASH_A,
      ["v1.2.3"]       = HASH_B,
    },
  }
  local got = collector.from_version(data, "^1.0.0")
  h.eq(got[1], HASH_B, "release before pre-release")
  h.eq(got[2], HASH_A, "pre-release after release")
end

h.suite("collector.from_version: custom normalize")
do
  local data = {
    fetched_at = {},
    branches   = {},
    tags       = {
      ["release-1.0.0"] = HASH_A,
      ["release-2.0.0"] = HASH_B,
    },
  }
  local function my_normalize(tags)
    local out = {}
    for _, t in ipairs(tags) do
      local bare = t:match("^release%-(.+)$")
      if bare then
        local maj, min, pat = bare:match("^(%d+)%.(%d+)%.(%d+)$")
        if maj then
          out[t] = { tonumber(maj), tonumber(min), tonumber(pat) }
        end
      end
    end
    return out
  end
  local got = collector.from_version(data, ">=1.0.0", my_normalize)
  h.eq(#got, 2,         "both custom-named tags matched")
  h.eq(got[1], HASH_B,  "release-2.0.0 first")
  h.eq(got[2], HASH_A,  "release-1.0.0 second")
end

h.suite("collector.from_version: duplicate hashes are deduplicated by highest version")
do
  -- Two tags pointing at the same hash; the candidate list should list the
  -- hash once at the position of its highest matching version.
  local data = {
    fetched_at = {},
    branches   = {},
    tags       = {
      ["v1.0.0"] = HASH_A,
      ["v1.1.0"] = HASH_A,  -- same hash, higher version
      ["v1.2.0"] = HASH_B,
    },
  }
  local got = collector.from_version(data, "^1.0.0")
  h.eq(#got, 2,        "hashes deduplicated")
  h.eq(got[1], HASH_B, "v1.2.0 first (HASH_B)")
  h.eq(got[2], HASH_A, "v1.1.0 represents HASH_A (higher of its tags)")
end

h.suite("collector.from_version: invalid range returns empty array")
do
  local data = { fetched_at = {}, branches = {}, tags = { ["v1.0.0"] = HASH_A } }
  local got = collector.from_version(data, "not-a-range")
  h.eq(#got, 0, "invalid range → empty")
end

h.suite("collector.from_version: no tags in store returns empty array")
do
  local data = { fetched_at = {}, branches = {}, tags = {} }
  local got = collector.from_version(data, ">=0.0.0")
  h.eq(#got, 0, "empty tags → empty candidates")
end

h.summary()
