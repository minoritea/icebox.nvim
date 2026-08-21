local h   = require("helpers")
local git = require("icebox.git")

-- Fixture dir is set by run_tests.sh via ICEBOX_FIXTURE_DIR env var.
local fixture_dir = vim.env.ICEBOX_FIXTURE_DIR
local repo_url    = "file://" .. fixture_dir .. "/repo.git"

-- Resolve fixture tip hashes at runtime so a machine-local git config
-- (e.g. commit.gpgsign) cannot desync the hard-coded expectations.
local function fixture_rev(ref)
  local out = vim.system({
    "git", "--git-dir=" .. fixture_dir .. "/repo.git", "rev-parse", ref,
  }, { text = true }):wait().stdout or ""
  return out:match("^([0-9a-f]+)")
end
local HASH1 = fixture_rev("refs/tags/v1.0.0")  -- commit 1 (oldest)
local HASH2 = fixture_rev("refs/heads/main")   -- commit 2 (newest)

-- git.fetch_*_sync is now a pure network operation: it returns the raw
-- new_data table (default_branch / fetched_at / branches / tags) and does
-- not touch the store. Callers are responsible for merging.

h.suite("git.fetch_tags_sync: default_branch and tags")
do
  local data, err = git.fetch_tags_sync(repo_url)
  h.is_nil(err,                     "no error")
  h.not_nil(data,                   "data returned")
  h.eq(data.default_branch, "main", "default_branch = main")
  h.eq(data.tags["v1.0.0"], HASH1,  "v1.0.0 → commit 1")
  h.eq(data.tags["v1.1.0"], HASH2,  "v1.1.0 → commit 2")
  h.eq(data.tags["v2.0.0"], HASH2,  "v2.0.0 (annotated) → real commit")
end

h.suite("git.fetch_tags_sync: fetched_at populated within a plausible window")
do
  local before = os.time()
  local data, _ = git.fetch_tags_sync(repo_url)
  local after  = os.time()

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
  local data, err = git.fetch_branch_sync(repo_url, "main", nil, fresh_cache_target())
  h.is_nil(err,                     "no error")
  h.not_nil(data,                   "data returned")
  h.eq(data.default_branch, "main", "default_branch = main")
  local hashes = data.branches["main"]
  h.not_nil(hashes,                 "branches.main present")
  h.eq(hashes[1], HASH2,            "newest commit first")
  h.eq(hashes[2], HASH1,            "oldest commit second")
end

h.suite("git.fetch_branch_sync: fetched_at populated within a plausible window")
do
  local before = os.time()
  local data, _ = git.fetch_branch_sync(repo_url, "main", nil, fresh_cache_target())
  local after  = os.time()

  local fa1 = data.fetched_at[HASH1]
  local fa2 = data.fetched_at[HASH2]
  h.not_nil(fa1,                            "fetched_at for HASH1 present")
  h.not_nil(fa2,                            "fetched_at for HASH2 present")
  h.is_true(fa1 >= before and fa1 <= after, "fetched_at for HASH1 in range")
end

h.suite("git.fetch_branch_sync: nil branch uses default_branch")
do
  local data, err = git.fetch_branch_sync(repo_url, nil, nil, fresh_cache_target())
  h.is_nil(err,                     "no error with nil branch")
  h.not_nil(data,                   "data returned")
  h.eq(data.default_branch, "main", "default_branch resolved")
  local hashes = data.branches["main"]
  h.not_nil(hashes,                 "branches.main present")
  h.eq(hashes[1], HASH2,            "newest commit first")
end

h.suite("git.fetch_branch_sync: limit caps commit count")
do
  local data, err = git.fetch_branch_sync(repo_url, "main", 1, fresh_cache_target())
  h.is_nil(err,                     "no error with limit")
  h.not_nil(data,                   "data returned")
  local hashes = data.branches["main"]
  h.eq(#hashes, 1,                  "only 1 commit returned")
  h.eq(hashes[1], HASH2,            "newest commit kept")
  h.is_nil(data.fetched_at[HASH1],  "older commit absent from fetched_at")
end

h.suite("git.fetch_tags_sync: invalid url returns error")
do
  local data, err = git.fetch_tags_sync("file:///nonexistent/path.git")
  h.is_nil(data, "no data on error")
  h.not_nil(err, "error returned")
end

-- Regression: a working-tree path named FETCH_HEAD must not make
-- `git log FETCH_HEAD` fail with "ambiguous argument ... both revision and
-- filename". thaw()'s clone_path / background-fetch path hits this log.
h.suite("git.fetch_branch_sync clone_path: FETCH_HEAD path collision")
do
  local isolated_bare = vim.fn.tempname() .. "-ambig-bare.git"
  vim.system({ "git", "clone", "--quiet", "--bare",
               fixture_dir .. "/repo.git", isolated_bare },
             { text = true }):wait()
  local clone_path = vim.fn.tempname() .. "-ambig-clone"
  vim.system({ "git", "clone", "--quiet", isolated_bare, clone_path },
             { text = true }):wait()
  -- Create a working-tree directory that collides with the FETCH_HEAD ref name.
  vim.fn.mkdir(clone_path .. "/FETCH_HEAD", "p")

  local data, err = git.fetch_branch_sync(
    "file://" .. isolated_bare, "main", nil, { clone_path = clone_path })
  h.is_nil(err, "no ambiguous-argument error when FETCH_HEAD path exists")
  h.not_nil(data, "data returned despite FETCH_HEAD path collision")
  h.eq(data and data.branches.main and data.branches.main[1], HASH2,
       "newest commit still resolved")

  vim.fn.delete(clone_path, "rf")
  vim.fn.delete(isolated_bare, "rf")
end

-- Regression: when the remote has both refs/heads/X and refs/tags/X with
-- different tips, a bare branch name makes git fetch prefer the tag.
-- icebox must qualify as refs/heads/X so the branch tip is recorded.
h.suite("git.fetch_branch_sync clone_path: branch wins over same-named tag")
do
  local isolated_bare = vim.fn.tempname() .. "-tagbranch-bare.git"
  vim.system({ "git", "clone", "--quiet", "--bare",
               fixture_dir .. "/repo.git", isolated_bare },
             { text = true }):wait()

  -- Point tag "main" at the older commit while branch "main" stays at HASH2.
  vim.system({ "git", "--git-dir=" .. isolated_bare,
               "tag", "-f", "main", HASH1 }, { text = true }):wait()
  local tag_tip = vim.system({ "git", "--git-dir=" .. isolated_bare,
                               "rev-parse", "refs/tags/main" },
                             { text = true }):wait().stdout or ""
  local branch_tip = vim.system({ "git", "--git-dir=" .. isolated_bare,
                                  "rev-parse", "refs/heads/main" },
                                { text = true }):wait().stdout or ""
  h.eq(tag_tip:match("^([0-9a-f]+)"), HASH1, "tag main → HASH1")
  h.eq(branch_tip:match("^([0-9a-f]+)"), HASH2, "branch main → HASH2")

  local clone_path = vim.fn.tempname() .. "-tagbranch-clone"
  vim.system({ "git", "clone", "--quiet", isolated_bare, clone_path },
             { text = true }):wait()

  local data, err = git.fetch_branch_sync(
    "file://" .. isolated_bare, "main", nil, { clone_path = clone_path })
  h.is_nil(err, "fetch with colliding tag/branch succeeds")
  h.not_nil(data, "data returned")
  h.eq(data and data.branches.main and data.branches.main[1], HASH2,
       "branch tip preferred over same-named tag")

  vim.fn.delete(clone_path, "rf")
  vim.fn.delete(isolated_bare, "rf")
end

h.summary()
