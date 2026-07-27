local h     = require("helpers")
local store = require("icebox.store")

local TEST_URL = "https://example.com/test-repo"

-- The store lives under $XDG_DATA_HOME/icebox.nvim/. Wipe that whole tree
-- between suites so each test starts with a pristine, unlocked state.
local function clean()
  vim.fn.delete(vim.env.XDG_DATA_HOME .. "/icebox.nvim", "rf")
end

h.suite("store.open / close: round-trip mutations to disk")
do
  clean()

  -- Fresh open on a URL with no store file yet: handle.data is empty.
  local h1, err1 = store.open(TEST_URL)
  h.not_nil(h1,             "open succeeds on fresh store")
  h.is_nil(err1,            "no error on fresh open")
  h.eq(next(h1.data.fetched_at), nil, "empty fetched_at on first open")

  -- Mutate in memory and close: writes to disk.
  h1.data.fetched_at["a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"] = 1700000000
  h1.data.branches["main"] = { "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" }
  h1.data.tags["v1.0.0"]   = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
  h1.data.default_branch   = "main"
  local ok, err = store.close(h1)
  h.is_true(ok,             "close succeeds")
  h.is_nil(err,             "no error on close")

  -- Reopen and confirm every field survives the round-trip.
  local h2 = store.open(TEST_URL)
  h.eq(h2.data.default_branch, "main", "default_branch round-trips")
  h.eq(h2.data.fetched_at["a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"], 1700000000,
       "fetched_at round-trips")
  h.eq(h2.data.branches["main"][1], "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
       "branch round-trips")
  h.eq(h2.data.tags["v1.0.0"], "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
       "tag round-trips")
  store.close(h2)
  clean()
end

h.suite("store.open: JSON decode failure returns nil + err")
do
  clean()
  local path = store.path_for(TEST_URL)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w"); f:write("not-json"); f:close()

  local handle, err = store.open(TEST_URL)
  h.is_nil(handle,                        "corrupted JSON returns nil handle")
  h.is_true(type(err) == "string",        "error message returned")
  -- open() must release the lock on the JSON-decode failure path too,
  -- otherwise the next test would time out.
  local retry_handle, _ = store.open(TEST_URL)
  h.is_nil(retry_handle,                  "lock released after failure (retry sees same broken store)")
  clean()
end

h.suite("store.open: lock times out when another handle holds it")
do
  clean()
  local h1 = store.open(TEST_URL)
  h.not_nil(h1, "first open acquires the lock")

  -- Second open with a short timeout should fail — h1 still holds the lock.
  local h2, err = store.open(TEST_URL, { timeout_ms = 200, retry_ms = 50 })
  h.is_nil(h2,   "second open times out while lock is held")
  h.is_true(type(err) == "string", "timeout error returned")

  store.close(h1)

  -- Once h1 released, a fresh open succeeds.
  local h3 = store.open(TEST_URL)
  h.not_nil(h3, "open succeeds after the holder closes")
  store.close(h3)
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

h.suite("store.auto_pin helpers")
do
  local data = {
    fetched_at = {}, branches = {}, tags = {},
    auto_pin = {}, initial_fetched = {},
  }
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
  local data = {
    fetched_at = {}, branches = {}, tags = {},
    auto_pin = {}, initial_fetched = {},
  }
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
