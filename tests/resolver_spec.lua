local h        = require("helpers")
local resolver = require("icebox.resolver")

local HASH_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local HASH_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local HASH_C = "cccccccccccccccccccccccccccccccccccccccc"
local HASH_D = "dddddddddddddddddddddddddddddddddddddddd"

local NOW          = 1700000000
local COOLDOWN_SEC = 7 * 86400
local OLD          = NOW - COOLDOWN_SEC - 1  -- cooled down
local RECENT       = NOW - 3600              -- not yet cooled down

h.suite("resolver: branch")
do
  local data = {
    fetched_at = { [HASH_A] = OLD, [HASH_B] = RECENT },
    branches   = { main = { HASH_B, HASH_A } },  -- HASH_B is newest
    tags       = {},
  }
  -- HASH_B is newest but not cooled; HASH_A is cooled
  local result = resolver.resolve(data, { branch = "main" }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_A, "returns newest cooled commit")
end

h.suite("resolver: branch all cooled")
do
  local data = {
    fetched_at = { [HASH_A] = OLD, [HASH_B] = OLD },
    branches   = { main = { HASH_B, HASH_A } },
    tags       = {},
  }
  local result = resolver.resolve(data, { branch = "main" }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_B, "returns newest when both cooled")
end

h.suite("resolver: branch none cooled")
do
  local data = {
    fetched_at = { [HASH_A] = RECENT },
    branches   = { main = { HASH_A } },
    tags       = {},
  }
  local result = resolver.resolve(data, { branch = "main" }, COOLDOWN_SEC, NOW)
  h.is_nil(result, "nil when nothing cooled")
end

h.suite("resolver: tag")
do
  local data = {
    fetched_at = { [HASH_A] = OLD },
    branches   = {},
    tags       = { ["v1.0.0"] = HASH_A },
  }
  local result = resolver.resolve(data, { tag = "v1.0.0" }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_A, "tag cooled returns hash")
end

h.suite("resolver: tag not cooled")
do
  local data = {
    fetched_at = { [HASH_A] = RECENT },
    branches   = {},
    tags       = { ["v1.0.0"] = HASH_A },
  }
  local result = resolver.resolve(data, { tag = "v1.0.0" }, COOLDOWN_SEC, NOW)
  h.is_nil(result, "tag not cooled returns nil")
end

h.suite("resolver: version range")
do
  local data = {
    fetched_at = {
      [HASH_A] = OLD,    -- v1.0.0
      [HASH_B] = OLD,    -- v1.2.0
      [HASH_C] = RECENT, -- v1.3.0 (not cooled)
    },
    branches = {},
    tags = {
      ["v1.0.0"] = HASH_A,
      ["v1.2.0"] = HASH_B,
      ["v1.3.0"] = HASH_C,
    },
  }
  local result = resolver.resolve(data, { version = "^1.0.0" }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_B, "returns highest cooled version in range")
end

h.suite("resolver: version v-prefix priority")
do
  local data = {
    fetched_at = { [HASH_A] = OLD, [HASH_B] = OLD },
    branches   = {},
    tags       = {
      ["v1.0.0"] = HASH_A,
      ["1.0.1"]  = HASH_B,  -- no v prefix, should be ignored
    },
  }
  local result = resolver.resolve(data, { version = ">=0.0.0" }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_A, "v-prefix tags take priority, non-v ignored")
end

h.suite("resolver: commit cooled")
do
  local data = {
    fetched_at = { [HASH_A] = OLD },
    branches   = {},
    tags       = {},
  }
  local result = resolver.resolve(data, { commit = HASH_A }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_A, "commit cooled returns hash")
end

h.suite("resolver: commit not cooled")
do
  local data = {
    fetched_at = { [HASH_A] = RECENT },
    branches   = {},
    tags       = {},
  }
  local result = resolver.resolve(data, { commit = HASH_A }, COOLDOWN_SEC, NOW)
  h.is_nil(result, "commit not cooled returns nil")
end

h.suite("resolver: version suffix tags")
do
  local data = {
    fetched_at = {
      [HASH_A] = OLD,    -- v1.2.3-alpha
      [HASH_B] = OLD,    -- v1.2.3
    },
    branches = {},
    tags = {
      ["v1.2.3-alpha"] = HASH_A,
      ["v1.2.3"]       = HASH_B,
    },
  }
  local result = resolver.resolve(data, { version = "^1.0.0" }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_B, "release preferred over pre-release")
end

h.suite("resolver: custom normalize")
do
  local data = {
    fetched_at = { [HASH_A] = OLD, [HASH_B] = OLD },
    branches   = {},
    tags       = {
      ["release-1.0.0"] = HASH_A,
      ["release-2.0.0"] = HASH_B,
    },
  }
  -- Custom normalize strips "release-" prefix before parsing
  local function my_normalize(tags)
    local result = {}
    for _, t in ipairs(tags) do
      local bare = t:match("^release%-(.+)$")
      if bare then
        local semver = require("icebox.semver")
        if semver.is_semver_tag(bare) then
          local major, minor, patch = bare:match("^(%d+)%.(%d+)%.(%d+)$")
          if major then
            result[t] = { tonumber(major), tonumber(minor), tonumber(patch) }
          end
        end
      end
    end
    return result
  end
  local result = resolver.resolve(data, { version = ">=1.0.0", normalize = my_normalize }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_B, "custom normalize: highest cooled version returned")
end

h.suite("resolver: branch + trusted_commit newer than cooled")
do
  -- HASH_C is HEAD (not cooled), HASH_B is next (not cooled), HASH_A is old (cooled).
  -- trusted_commit = HASH_C is on the branch and newer than the cooled HASH_A.
  local data = {
    fetched_at = { [HASH_A] = OLD, [HASH_B] = RECENT, [HASH_C] = RECENT },
    branches   = { main = { HASH_C, HASH_B, HASH_A } },
    tags       = {},
  }
  local result = resolver.resolve(data, { branch = "main", trusted_commit = HASH_C }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_C, "trusted_commit preferred when it is newer on branch")
end

h.suite("resolver: branch + trusted_commit older than newest cooled")
do
  -- HASH_C cooled (newest), HASH_B cooled, HASH_A cooled (oldest).
  -- trusted_commit = HASH_A is on the branch but older than HASH_C.
  local data = {
    fetched_at = { [HASH_A] = OLD, [HASH_B] = OLD, [HASH_C] = OLD },
    branches   = { main = { HASH_C, HASH_B, HASH_A } },
    tags       = {},
  }
  local result = resolver.resolve(data, { branch = "main", trusted_commit = HASH_A }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_C, "newest cooled preferred when trusted_commit is older on branch")
end

h.suite("resolver: branch + trusted_commit not on branch")
do
  -- trusted_commit = HASH_D is not in the branch candidate set → ignored.
  local data = {
    fetched_at = { [HASH_A] = OLD, [HASH_B] = RECENT },
    branches   = { main = { HASH_B, HASH_A } },
    tags       = {},
  }
  local result = resolver.resolve(data, { branch = "main", trusted_commit = HASH_D }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_A, "trusted_commit outside candidate set is ignored")
end

h.suite("resolver: branch + trusted_commit not on branch, nothing cooled")
do
  local data = {
    fetched_at = { [HASH_A] = RECENT },
    branches   = { main = { HASH_A } },
    tags       = {},
  }
  local result = resolver.resolve(data, { branch = "main", trusted_commit = HASH_D }, COOLDOWN_SEC, NOW)
  h.is_nil(result, "nil when trusted_commit is off-branch and nothing cooled")
end

h.suite("resolver: branch + trusted_commit is the only cooled option")
do
  -- Nothing cooled, but trusted_commit is on the branch → return it.
  local data = {
    fetched_at = { [HASH_A] = RECENT, [HASH_B] = RECENT },
    branches   = { main = { HASH_B, HASH_A } },
    tags       = {},
  }
  local result = resolver.resolve(data, { branch = "main", trusted_commit = HASH_A }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_A, "trusted_commit returned when in candidate set and nothing cooled")
end

h.suite("resolver: tag + trusted_commit matches tag hash")
do
  local data = {
    fetched_at = { [HASH_A] = RECENT },
    branches   = {},
    tags       = { ["v1.0.0"] = HASH_A },
  }
  local result = resolver.resolve(data, { tag = "v1.0.0", trusted_commit = HASH_A }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_A, "trusted_commit returned even without cooldown when tag matches")
end

h.suite("resolver: tag + trusted_commit mismatch, not cooled")
do
  local data = {
    fetched_at = { [HASH_A] = RECENT },
    branches   = {},
    tags       = { ["v1.0.0"] = HASH_A },
  }
  local result = resolver.resolve(data, { tag = "v1.0.0", trusted_commit = HASH_B }, COOLDOWN_SEC, NOW)
  h.is_nil(result, "nil when trusted_commit off-tag and tag not cooled")
end

h.suite("resolver: version + trusted_commit newer than newest cooled")
do
  -- v1.3.0 (HASH_C) is not cooled; v1.2.0 (HASH_B) is cooled.
  -- trusted_commit = HASH_C points at the highest matching tag → prefer it.
  local data = {
    fetched_at = {
      [HASH_A] = OLD,    -- v1.0.0
      [HASH_B] = OLD,    -- v1.2.0
      [HASH_C] = RECENT, -- v1.3.0
    },
    branches = {},
    tags = {
      ["v1.0.0"] = HASH_A,
      ["v1.2.0"] = HASH_B,
      ["v1.3.0"] = HASH_C,
    },
  }
  local result = resolver.resolve(data, { version = "^1.0.0", trusted_commit = HASH_C }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_C, "trusted_commit preferred when it is a higher tag in range")
end

h.suite("resolver: version + trusted_commit older tag than newest cooled")
do
  local data = {
    fetched_at = { [HASH_A] = OLD, [HASH_B] = OLD },
    branches   = {},
    tags       = {
      ["v1.0.0"] = HASH_A,
      ["v1.2.0"] = HASH_B,
    },
  }
  local result = resolver.resolve(data, { version = "^1.0.0", trusted_commit = HASH_A }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_B, "newest cooled tag preferred when trusted_commit tag is older")
end

h.suite("resolver: version + trusted_commit not in range")
do
  local data = {
    fetched_at = { [HASH_A] = OLD, [HASH_B] = OLD, [HASH_C] = OLD },
    branches   = {},
    tags       = {
      ["v1.0.0"] = HASH_A,
      ["v1.2.0"] = HASH_B,
      ["v2.0.0"] = HASH_C,  -- outside ^1.0.0
    },
  }
  local result = resolver.resolve(data, { version = "^1.0.0", trusted_commit = HASH_C }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_B, "trusted_commit outside range is ignored")
end

h.suite("resolver: commit + trusted_commit equals target, not cooled")
do
  local data = {
    fetched_at = { [HASH_A] = RECENT },
    branches   = {},
    tags       = {},
  }
  local result = resolver.resolve(data, { commit = HASH_A, trusted_commit = HASH_A }, COOLDOWN_SEC, NOW)
  h.eq(result, HASH_A, "trusted_commit==commit returns it even when not cooled")
end

h.summary()
