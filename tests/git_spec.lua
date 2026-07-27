local h     = require("helpers")
local git   = require("icebox.git")
local store = require("icebox.store")

-- Deterministic hashes produced by setup_fixtures.sh
-- commit 1 (oldest, tagged v1.0.0)
local HASH1 = "aa8a8ef72994fa7b4f5f07d02deded583af3f45d"
-- commit 2 (newest, tagged v1.1.0 + v2.0.0 annotated)
local HASH2 = "d708048f457e3b2e95dce2671c9ba38f1d2e1706"

-- Fixture dir is set by run_tests.sh via ICEBOX_FIXTURE_DIR env var.
local fixture_dir = vim.env.ICEBOX_FIXTURE_DIR
local repo_url    = "file://" .. fixture_dir .. "/repo.git"

-- Every fetch persists into $XDG_DATA_HOME/icebox.nvim/<sha>.json under the
-- URL lock. Reset that state before each suite so we exercise the fresh-fetch
-- path deterministically.
local function reset()
  local xdg_cache = vim.env.XDG_CACHE_HOME
  if not xdg_cache or xdg_cache == "" then xdg_cache = vim.fn.expand("~/.cache") end
  vim.fn.delete(vim.env.XDG_DATA_HOME .. "/icebox.nvim", "rf")
  vim.fn.delete(xdg_cache             .. "/icebox.nvim", "rf")
end

h.suite("git.fetch_tags_sync: default_branch and tags persisted to store")
do
  reset()
  local ok, err = git.fetch_tags_sync(repo_url)
  h.is_nil(err,   "no error")
  h.is_true(ok,   "returns true on success")

  local data = store.read(repo_url)
  h.eq(data.default_branch, "main", "default_branch = main")
  h.eq(data.tags["v1.0.0"], HASH1,  "v1.0.0 → commit 1")
  h.eq(data.tags["v1.1.0"], HASH2,  "v1.1.0 → commit 2")
  h.eq(data.tags["v2.0.0"], HASH2,  "v2.0.0 (annotated) → real commit")
end

h.suite("git.fetch_tags_sync: fetched_at populated within a plausible window")
do
  reset()
  local before = os.time()
  git.fetch_tags_sync(repo_url)
  local after  = os.time()

  local data = store.read(repo_url)
  local fa1 = data.fetched_at[HASH1]
  local fa2 = data.fetched_at[HASH2]
  h.not_nil(fa1,                            "fetched_at for HASH1 present")
  h.not_nil(fa2,                            "fetched_at for HASH2 present")
  h.is_true(fa1 >= before and fa1 <= after, "fetched_at for HASH1 in range")
  h.is_true(fa2 >= before and fa2 <= after, "fetched_at for HASH2 in range")
end

local function fresh_cache_target()
  return { cache_dir = vim.fn.tempname() .. "-cache" }
end

h.suite("git.fetch_branch_sync: commit order and default_branch")
do
  reset()
  local ok, err = git.fetch_branch_sync(repo_url, "main", nil, fresh_cache_target())
  h.is_nil(err,   "no error")
  h.is_true(ok,   "returns true on success")

  local data = store.read(repo_url)
  h.eq(data.default_branch, "main", "default_branch = main")
  local hashes = data.branches["main"]
  h.not_nil(hashes,                 "branches.main present")
  h.eq(hashes[1], HASH2,            "newest commit first")
  h.eq(hashes[2], HASH1,            "oldest commit second")
end

h.suite("git.fetch_branch_sync: fetched_at populated within a plausible window")
do
  reset()
  local before = os.time()
  git.fetch_branch_sync(repo_url, "main", nil, fresh_cache_target())
  local after  = os.time()

  local data = store.read(repo_url)
  local fa1 = data.fetched_at[HASH1]
  local fa2 = data.fetched_at[HASH2]
  h.not_nil(fa1,                            "fetched_at for HASH1 present")
  h.not_nil(fa2,                            "fetched_at for HASH2 present")
  h.is_true(fa1 >= before and fa1 <= after, "fetched_at for HASH1 in range")
end

h.suite("git.fetch_branch_sync: nil branch uses default_branch")
do
  reset()
  local ok, err = git.fetch_branch_sync(repo_url, nil, nil, fresh_cache_target())
  h.is_nil(err,   "no error with nil branch")
  h.is_true(ok,   "returns true on success")

  local data = store.read(repo_url)
  h.eq(data.default_branch, "main", "default_branch resolved")
  local hashes = data.branches["main"]
  h.not_nil(hashes,                 "branches.main present")
  h.eq(hashes[1], HASH2,            "newest commit first")
end

h.suite("git.fetch_branch_sync: limit caps commit count")
do
  reset()
  local ok, err = git.fetch_branch_sync(repo_url, "main", 1, fresh_cache_target())
  h.is_nil(err,   "no error with limit")
  h.is_true(ok,   "returns true on success")

  local data = store.read(repo_url)
  local hashes = data.branches["main"]
  h.eq(#hashes, 1,                  "only 1 commit returned")
  h.eq(hashes[1], HASH2,            "newest commit kept")
  h.is_nil(data.fetched_at[HASH1],  "older commit absent from fetched_at")
end

h.suite("git.fetch_tags_sync: invalid url returns error")
do
  reset()
  local ok, err = git.fetch_tags_sync("file:///nonexistent/path.git")
  h.is_nil(ok,   "no ok on error")
  h.not_nil(err, "error returned")
end

h.summary()
