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

h.suite("store.exists")
do
  clean()
  h.is_false(store.exists(TEST_URL), "exists false before write")

  local data = store.read(TEST_URL)
  data.fetched_at["a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"] = 1700000000
  store.write(TEST_URL, data)

  h.is_true(store.exists(TEST_URL), "exists true after write")
  clean()
end

h.suite("store.read: JSON decode failure returns nil + err")
do
  clean()
  local path = store.path_for(TEST_URL)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  f:write("not-json")
  f:close()

  local data, err = store.read(TEST_URL)
  h.is_nil(data, "corrupted JSON returns nil")
  h.is_true(type(err) == "string", "error message returned")
  clean()
end

h.suite("store.auto_pin helpers")
do
  local data = store.read(TEST_URL)
  h.is_nil(store.get_auto_pin(data, "branch:main"),
    "get_auto_pin returns nil when unset")

  store.set_auto_pin(data, "branch:main",
    "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
  h.eq(store.get_auto_pin(data, "branch:main"),
    "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
    "set_auto_pin persists across get")
end

h.suite("store.initial_fetched helpers")
do
  local data = store.read(TEST_URL)
  h.is_false(store.is_initial_fetched(data, "branch:main"),
    "is_initial_fetched false when unset")

  store.mark_initial_fetched(data, "branch:main")
  h.is_true(store.is_initial_fetched(data, "branch:main"),
    "mark_initial_fetched flips to true")
  h.is_false(store.is_initial_fetched(data, "branch:develop"),
    "unrelated key stays false")
end

h.suite("store.merge with auto_pin / initial_fetched")
do
  local existing = {
    fetched_at      = {},
    branches        = {},
    tags            = {},
    auto_pin     = { ["branch:main"] = "aa" },
    initial_fetched = { ["branch:main"] = true },
  }
  local new_data = {
    auto_pin     = { ["branch:main"] = "bb", ["version:^1.0.0"] = "cc" },
    initial_fetched = { ["default"] = true },
  }
  store.merge(existing, new_data)
  h.eq(existing.auto_pin["branch:main"], "bb",
    "auto_pin overwritten by new data")
  h.eq(existing.auto_pin["version:^1.0.0"], "cc",
    "new auto_pin entry added")
  h.is_true(existing.initial_fetched["branch:main"],
    "existing initial_fetched preserved when new data omits key")
  h.is_true(existing.initial_fetched["default"],
    "new initial_fetched entry added")
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

h.suite("store.has_semver_tags")
do
  local empty = { fetched_at = {}, branches = {}, tags = {} }
  h.is_false(store.has_semver_tags(empty), "empty store has no semver tags")

  local non_semver = {
    fetched_at = {},
    branches   = {},
    tags       = { ["not-semver"] = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" },
  }
  h.is_false(store.has_semver_tags(non_semver), "non-semver tag not counted")

  local semver_tag = {
    fetched_at = {},
    branches   = {},
    tags       = { ["v1.0.0"] = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" },
  }
  h.is_true(store.has_semver_tags(semver_tag), "semver tag counted")
end

h.summary()
