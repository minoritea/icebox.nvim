local h   = require("helpers")
local git = require("icebox.git")

-- Deterministic hashes produced by setup_fixtures.sh
-- commit 1 (oldest, tagged v1.0.0)
local HASH1 = "aa8a8ef72994fa7b4f5f07d02deded583af3f45d"
-- commit 2 (newest, tagged v1.1.0 + v2.0.0 annotated)
local HASH2 = "d708048f457e3b2e95dce2671c9ba38f1d2e1706"

-- Fixture dir is set by run_tests.sh via ICEBOX_FIXTURE_DIR env var.
local fixture_dir = vim.env.ICEBOX_FIXTURE_DIR
local repo_url    = "file://" .. fixture_dir .. "/repo.git"

h.suite("git.fetch_tags_sync: default_branch")
do
  local data, err = git.fetch_tags_sync(repo_url)
  h.is_nil(err,                        "no error")
  h.not_nil(data,                      "data returned")
  h.eq(data.default_branch, "main",    "default_branch = main")
end

h.suite("git.fetch_tags_sync: tag hashes")
do
  local data, err = git.fetch_tags_sync(repo_url)
  h.is_nil(err, "no error")
  h.eq(data.tags["v1.0.0"], HASH1,     "v1.0.0 → commit 1")
  h.eq(data.tags["v1.1.0"], HASH2,     "v1.1.0 → commit 2")
  h.eq(data.tags["v2.0.0"], HASH2,     "v2.0.0 (annotated) → real commit")
end

h.suite("git.fetch_tags_sync: fetched_at populated")
do
  local before = os.time()
  local data, _ = git.fetch_tags_sync(repo_url)
  local after  = os.time()
  local fa1 = data.fetched_at[HASH1]
  local fa2 = data.fetched_at[HASH2]
  h.not_nil(fa1,                       "fetched_at for HASH1 present")
  h.not_nil(fa2,                       "fetched_at for HASH2 present")
  h.is_true(fa1 >= before and fa1 <= after, "fetched_at for HASH1 in range")
  h.is_true(fa2 >= before and fa2 <= after, "fetched_at for HASH2 in range")
end

h.suite("git.fetch_branch_sync: commit order and default_branch")
do
  local data, err = git.fetch_branch_sync(repo_url, "main")
  h.is_nil(err,                        "no error")
  h.not_nil(data,                      "data returned")
  h.eq(data.default_branch, "main",    "default_branch = main")
  local hashes = data.branches["main"]
  h.not_nil(hashes,                    "branches.main present")
  h.eq(hashes[1], HASH2,               "newest commit first")
  h.eq(hashes[2], HASH1,               "oldest commit second")
end

h.suite("git.fetch_branch_sync: fetched_at populated")
do
  local before = os.time()
  local data, _ = git.fetch_branch_sync(repo_url, "main")
  local after  = os.time()
  local fa1 = data.fetched_at[HASH1]
  local fa2 = data.fetched_at[HASH2]
  h.not_nil(fa1,                       "fetched_at for HASH1 present")
  h.not_nil(fa2,                       "fetched_at for HASH2 present")
  h.is_true(fa1 >= before and fa1 <= after, "fetched_at for HASH1 in range")
end

h.suite("git.fetch_branch_sync: nil branch uses default")
do
  local data, err = git.fetch_branch_sync(repo_url, nil)
  h.is_nil(err,                        "no error with nil branch")
  h.not_nil(data,                      "data returned")
  h.eq(data.default_branch, "main",    "default_branch resolved")
  -- branch key is default_branch when nil passed
  local hashes = data.branches["main"]
  h.not_nil(hashes,                    "branches.main present")
  h.eq(hashes[1], HASH2,              "newest commit first")
end

h.suite("git.fetch_tags_sync: invalid url returns error")
do
  local data, err = git.fetch_tags_sync("file:///nonexistent/path.git")
  h.is_nil(data,   "no data on error")
  h.not_nil(err,   "error returned")
end

h.summary()
