local h     = require("helpers")
local store = require("icebox.store")

local TEST_URL = "https://example.com/test-repo"

local function clean()
  local path = store.path_for(TEST_URL)
  os.remove(path)
  os.remove(store.lock_path_for(TEST_URL))
end

h.suite("store.read / write round-trip")
do
  clean()
  local data = store.read(TEST_URL)
  h.eq(next(data.fetched_at), nil, "empty fetched_at on first read")

  data.fetched_at["a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"] = 1700000000
  data.branches["main"] = { "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" }
  data.tags["v1.0.0"] = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
  data.default_branch = "main"

  local ok, err = store.write(TEST_URL, data)
  h.is_true(ok, "write succeeds")

  local read_back = store.read(TEST_URL)
  h.eq(read_back.default_branch, "main", "default_branch round-trips")
  h.eq(read_back.fetched_at["a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"], 1700000000, "fetched_at round-trips")
  h.eq(read_back.branches["main"][1], "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "branch round-trips")
  h.eq(read_back.tags["v1.0.0"], "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "tag round-trips")
  clean()
end

h.suite("store.merge")
do
  local existing = { fetched_at = {}, branches = {}, tags = {} }

  existing.fetched_at["aabbccddaabbccddaabbccddaabbccddaabbccdd00"] = 1000

  local new_data = {
    default_branch = "main",
    fetched_at = {
      ["aabbccddaabbccddaabbccddaabbccddaabbccdd00"] = 9999,  -- should NOT overwrite
      ["bbccddeebbccddeebbccddeebbccddeebbccddee00"] = 2000,
    },
    branches = { main = { "bbccddeebbccddeebbccddeebbccddeebbccddee00" } },
    tags     = { ["v1.0.0"] = "bbccddeebbccddeebbccddeebbccddeebbccddee00" },
  }

  store.merge(existing, new_data)

  h.eq(existing.default_branch, "main",   "default_branch merged")
  h.eq(existing.fetched_at["aabbccddaabbccddaabbccddaabbccddaabbccdd00"], 1000,
       "existing fetched_at not overwritten")
  h.eq(existing.fetched_at["bbccddeebbccddeebbccddeebbccddeebbccddee00"], 2000,
       "new fetched_at added")
  h.eq(existing.branches["main"][1], "bbccddeebbccddeebbccddeebbccddeebbccddee00",
       "branch overwritten")
  h.eq(existing.tags["v1.0.0"], "bbccddeebbccddeebbccddeebbccddeebbccddee00",
       "tag added")
end

h.suite("store sanitize (bad data ignored)")
do
  clean()
  local path = store.path_for(TEST_URL)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  f:write(vim.json.encode({
    default_branch = "main",
    fetched_at = {
      ["INVALIDHASH"] = 1000,
      ["a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"] = 2000,
    },
    branches = { main = { "BADHASH", "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" } },
    tags = {
      ["v1.0.0"] = "BADHASH",
      ["../evil"] = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
      ["v2.0.0"] = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
    },
  }))
  f:close()

  local data = store.read(TEST_URL)
  h.is_nil(data.fetched_at["INVALIDHASH"],              "bad hash in fetched_at stripped")
  h.eq(data.fetched_at["a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"], 2000,
       "valid hash in fetched_at kept")
  h.eq(#data.branches["main"], 1,                       "bad hash in branch stripped")
  h.is_nil(data.tags["v1.0.0"],                         "bad hash in tags stripped")
  h.is_nil(data.tags["../evil"],                        "bad tag name stripped")
  h.eq(data.tags["v2.0.0"], "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
       "valid tag kept")
  clean()
end

h.suite("store.lock / unlock")
do
  clean()
  local acquired = store.lock(TEST_URL)
  h.is_true(acquired, "first lock succeeds")

  local second = store.lock(TEST_URL)
  h.is_false(second, "second lock fails (same PID holds it)")

  store.unlock(TEST_URL)
  local after_unlock = store.lock(TEST_URL)
  h.is_true(after_unlock, "lock after unlock succeeds")
  store.unlock(TEST_URL)
  clean()
end

h.suite("store.has_records / has_semver_tags")
do
  local empty = { fetched_at = {}, branches = {}, tags = {} }
  h.is_false(store.has_records(empty),     "empty store has no records")
  h.is_false(store.has_semver_tags(empty), "empty store has no semver tags")

  local with_commit = {
    fetched_at = { ["a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"] = 1000 },
    branches   = {},
    tags       = {},
  }
  h.is_true(store.has_records(with_commit),     "store with commit hash has records")
  h.is_false(store.has_semver_tags(with_commit), "store with no tags has no semver tags")

  -- has_records=true but default_branch=nil and no semver tags:
  -- this is the edge case from B1 where bg_fetch must still fire.
  local no_branch_no_tags = {
    fetched_at = { ["a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"] = 1000 },
    branches   = {},
    tags       = { ["not-semver"] = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" },
  }
  h.is_true(store.has_records(no_branch_no_tags),     "has_records true without branch")
  h.is_false(store.has_semver_tags(no_branch_no_tags), "non-semver tag not counted")
end

h.summary()
