local h        = require("helpers")
local config   = require("icebox.config")
local store    = require("icebox.store")
local icebox   = require("icebox")

-- Deterministic hashes produced by setup_fixtures.sh
local HASH1 = "aa8a8ef72994fa7b4f5f07d02deded583af3f45d"  -- commit 1 (older, tagged v1.0.0)
local HASH2 = "d708048f457e3b2e95dce2671c9ba38f1d2e1706"  -- commit 2 (newer, tagged v1.1.0 + v2.0.0)

local fixture_dir = vim.env.ICEBOX_FIXTURE_DIR
local repo_url    = "file://" .. fixture_dir .. "/repo.git"

-- Purge on-disk state so each suite starts clean. Some suites work against
-- URLs other than `repo_url` (e.g. isolated_bare origins for clone_path
-- tests), so wipe the whole icebox trees rather than a single URL's paths.
local function reset_all()
  local xdg_cache = vim.env.XDG_CACHE_HOME
  if not xdg_cache or xdg_cache == "" then xdg_cache = vim.fn.expand("~/.cache") end
  vim.fn.delete(vim.env.XDG_DATA_HOME .. "/icebox.nvim", "rf")
  vim.fn.delete(xdg_cache             .. "/icebox.nvim", "rf")
end

reset_all()

h.suite("config.merge_overrides")
do
  config.set({})  -- reset to defaults
  local cfg = config.merge_overrides({})
  h.eq(cfg.cooldown_days, 7,             "default cooldown_days=7")
  h.eq(cfg.trust_initial_pin, false,     "default trust_initial_pin=false")
  h.eq(cfg.branch_commits_per_fetch, 500, "default branch_commits_per_fetch=500")

  config.set({ cooldown_days = 3 })
  cfg = config.merge_overrides({})
  h.eq(cfg.cooldown_days, 3,             "setup value used when no override")

  cfg = config.merge_overrides({ cooldown_days = 30 })
  h.eq(cfg.cooldown_days, 30,            "override wins over setup")

  -- The setup value should not have been mutated
  h.eq(config.get().cooldown_days, 3,    "setup value untouched by override")

  config.set({ cooldown_days = 7 })  -- restore default for later suites
end

h.suite("config.set idempotence")
do
  config.set({ cooldown_days = 30, trust_initial_pin = true,
               branch_commits_per_fetch = 100 })
  -- Second call with a subset of keys must reset the unspecified keys to
  -- their defaults, not preserve them from the previous call.
  config.set({ trust_initial_pin = true })
  local cfg = config.get()
  h.eq(cfg.cooldown_days, 7,              "cooldown_days back to default")
  h.eq(cfg.trust_initial_pin, true,       "trust_initial_pin retained via opts")
  h.eq(cfg.branch_commits_per_fetch, 500, "branch_commits_per_fetch back to default")

  -- Empty opts resets everything to defaults.
  config.set({})
  cfg = config.get()
  h.eq(cfg.cooldown_days, 7,              "empty opts → cooldown_days default")
  h.eq(cfg.trust_initial_pin, false,      "empty opts → trust_initial_pin default")
  h.eq(cfg.branch_commits_per_fetch, 500, "empty opts → branch_commits_per_fetch default")
end

h.suite("config defaults without setup call")
do
  -- Reload icebox and config as if this were a fresh process where setup()
  -- was never invoked. Defaults must still produce a working thaw path.
  package.loaded["icebox"]        = nil
  package.loaded["icebox.config"] = nil
  local fresh_config = require("icebox.config")
  local cfg = fresh_config.merge_overrides({})
  h.eq(cfg.cooldown_days, 7,           "cooldown_days defaults to 7")
  h.eq(cfg.trust_initial_pin, false,   "trust_initial_pin defaults to false")
  h.eq(cfg.branch_commits_per_fetch, 500, "branch_commits_per_fetch defaults to 500")
  package.loaded["icebox"]        = nil
  package.loaded["icebox.config"] = nil
  icebox = require("icebox")
end

h.suite("thaw opts override: cooldown_days")
do
  reset_all()
  -- Prime the store with fetched_at from 3 days ago
  local data = store.read(repo_url)
  data.fetched_at[HASH2] = os.time() - 3 * 86400
  data.branches["main"]  = { HASH2 }
  store.write(repo_url, data)

  icebox.setup({ cooldown_days = 7 })
  local got = icebox.thaw(repo_url, { branch = "main" })
  h.eq(got, icebox.ZERO_HASH,   "default cooldown=7 excludes 3-day-old commit")

  got = icebox.thaw(repo_url, { branch = "main", cooldown_days = 1 })
  h.eq(got, HASH2,              "per-call cooldown=1 accepts 3-day-old commit")

  h.eq(config.get().cooldown_days, 7, "setup cooldown_days unchanged")
end

h.suite("thaw opts override: branch_commits_per_fetch (sync path)")
do
  reset_all()
  -- fixture has 2 commits on main; override caps the fetch to 1.
  -- setup value is deliberately larger (500 default) so the assertion
  -- exercises "override wins over setup". cooldown_days=0 is required for
  -- the initial sync fetch to return a non-zero hash on the very first call.
  icebox.setup({ branch_commits_per_fetch = 500 })
  local got = icebox.thaw(repo_url, {
    branch                   = "main",
    branch_commits_per_fetch = 1,
    cooldown_days            = 0,
  })
  h.eq(got, HASH2, "override fetch still returns newest commit")

  local data = store.read(repo_url)
  h.eq(#data.branches["main"], 1, "branches.main capped to 1 entry")
  h.eq(data.branches["main"][1], HASH2, "capped entry is the newest commit")
  h.is_nil(data.fetched_at[HASH1], "older commit outside cap is absent from fetched_at")

  -- setup value must not be mutated by the per-call override
  h.eq(config.get().branch_commits_per_fetch, 500, "setup value unchanged")
end

h.suite("thaw opts override: branch_commits_per_fetch (async / bg_fetch path)")
do
  -- Drain any bg_fetch closures scheduled by previous suites so their fetches
  -- don't race with this suite's assertion (they'd otherwise consume the URL
  -- lock and hide whether *our* bg_fetch used the override).
  vim.wait(2000, function() return false end, 20)
  reset_all()

  -- Prime a populated store (and mark it initial_fetched) so thaw() skips
  -- the initial sync fetch and only exercises the bg_fetch path. The primed
  -- data intentionally contains a fake extra hash so we can observe
  -- bg_fetch replacing branches.main entirely with the freshly-fetched
  -- (capped) list.
  local FAKE = "ffffffffffffffffffffffffffffffffffffffff"
  local data = store.read(repo_url)
  data.fetched_at[HASH2] = os.time() - 30 * 86400
  data.fetched_at[FAKE]  = os.time() - 30 * 86400
  data.branches["main"]  = { HASH2, FAKE }
  -- Pretend we've already sync-fetched this route so thaw() skips step 2
  -- and dispatches straight to bg_fetch.
  store.mark_initial_fetched(data, "branch:main")
  store.write(repo_url, data)

  icebox.setup({ branch_commits_per_fetch = 500 })
  -- Kicks off bg_fetch with the override embedded in cfg.
  icebox.thaw(repo_url, {
    branch                   = "main",
    branch_commits_per_fetch = 1,
  })

  -- Wait for bg_fetch to finish: it releases the URL's store lock on exit,
  -- and branches.main is overwritten with the freshly-fetched (capped) list.
  local settled = vim.wait(5000, function()
    local d = store.read(repo_url)
    return d.branches["main"]
      and #d.branches["main"] == 1
      and d.branches["main"][1] == HASH2
  end, 20)
  h.is_true(settled, "bg_fetch settled within timeout")

  local after = store.read(repo_url)
  h.eq(#after.branches["main"], 1,
    "bg_fetch used the per-call override (branches capped to 1)")
  h.eq(after.branches["main"][1], HASH2, "capped entry is the newest commit")
end

h.suite("trust_on_first_use is retired")
do
  reset_all()

  -- setup() with the retired key must raise (breaking, but explicit).
  local ok, err = pcall(icebox.setup, { trust_on_first_use = true })
  h.is_false(ok, "setup({trust_on_first_use=...}) raises")
  h.is_true(err and err:find("trust_on_first_use") ~= nil,
    "error mentions the retired option name")

  -- Restore a clean setup for the rest of the suite (last call raised
  -- before it could store the config).
  icebox.setup({})

  -- thaw() with the retired opt: return ZERO_HASH via the validate error
  -- path, not by raising.
  local got = icebox.thaw(repo_url, { branch = "main", trust_on_first_use = true })
  h.eq(got, icebox.ZERO_HASH,
    "thaw({trust_on_first_use=...}) → validate rejects → ZERO_HASH")
end

h.suite("thaw cache: bare clone persists under XDG_CACHE_HOME")
do
  reset_all()
  local cache_dir = store.cache_dir_for(repo_url)

  icebox.setup({})
  icebox.thaw(repo_url, { branch = "main" })

  h.is_true(vim.fn.isdirectory(cache_dir) == 1, "cache_dir exists after thaw")
  local r = vim.system({ "git", "-C", cache_dir, "rev-parse", "--git-dir" },
                       { text = true }):wait()
  h.eq(r.code, 0, "cache_dir is a healthy git repo")
end

h.suite("thaw cache: reuse existing cache on second call")
do
  reset_all()
  local cache_dir = store.cache_dir_for(repo_url)

  icebox.setup({})
  icebox.thaw(repo_url, { branch = "main" })

  -- Assert cache reuse via HEAD inode.
  --
  -- An earlier version of this suite dropped a marker file into cache_dir
  -- and checked that the marker still existed after the second thaw. That
  -- only proves the directory was not wiped — it can't tell "reused" apart
  -- from "wiped and re-cloned but the unrelated marker happened to survive".
  -- .git/HEAD is created fresh on every clone, so an unchanged inode across
  -- two thaws is a strong signal that the whole bare clone was reused as-is.
  local head_path = cache_dir .. "/HEAD"
  local before = vim.uv.fs_stat(head_path)
  h.not_nil(before, "cache HEAD exists after first thaw")

  local data = store.read(repo_url)
  data.fetched_at = {}
  data.branches   = {}
  store.write(repo_url, data)

  icebox.thaw(repo_url, { branch = "main" })

  local after = vim.uv.fs_stat(head_path)
  h.not_nil(after, "cache HEAD still exists after second thaw")
  h.eq(after and after.ino, before and before.ino,
    "HEAD inode unchanged → cache dir was reused (not re-cloned)")
end

h.suite("thaw cache: rebuild when cache is broken")
do
  reset_all()
  local cache_dir = store.cache_dir_for(repo_url)
  vim.fn.mkdir(cache_dir, "p")
  -- Junk directory that fails the git-dir health check
  local f = io.open(cache_dir .. "/junk", "w")
  if f then f:write("garbage"); f:close() end

  icebox.setup({})
  local got = icebox.thaw(repo_url, { branch = "main", cooldown_days = 0 })
  h.eq(got, HASH2, "broken cache is rebuilt and thaw succeeds")
end

h.suite("thaw clone_path: fetch is non-destructive on refs")
do
  reset_all()
  -- Isolated bare + user clone: the clone_path's `origin` must not point at
  -- the shared fixture bare repo, otherwise icebox's fetch on that origin
  -- would touch the fixture and affect later tests.
  local isolated_bare = vim.fn.tempname() .. "-bare.git"
  vim.system({ "git", "clone", "--quiet", "--bare",
               fixture_dir .. "/repo.git", isolated_bare },
             { text = true }):wait()
  local clone_path = vim.fn.tempname() .. "-lr"
  vim.system({ "git", "clone", "--quiet", isolated_bare, clone_path },
             { text = true }):wait()

  local function snapshot()
    local out = vim.system({ "git", "-C", clone_path, "show-ref" },
                           { text = true }):wait().stdout or ""
    local head = vim.system({ "git", "-C", clone_path, "rev-parse", "HEAD" },
                            { text = true }):wait().stdout or ""
    return out, head
  end
  local refs_before, head_before = snapshot()

  -- FETCH_HEAD is not created by `git clone`; it only appears after a
  -- subsequent `git fetch`. Confirm it is absent up front so its presence
  -- after thaw() is a positive signal that the fetch actually ran.
  local fetch_head_path = clone_path .. "/.git/FETCH_HEAD"
  h.is_nil(vim.uv.fs_stat(fetch_head_path),
    "FETCH_HEAD absent before thaw (fresh clone)")

  icebox.setup({ cooldown_days = 0 })
  -- url + clone_path together is a parse error; use the single-table form.
  local got = icebox.thaw({
    clone_path         = clone_path,
    branch             = "main",
  })
  h.eq(got, HASH2, "clone_path path returns newest commit")

  local refs_after, head_after = snapshot()
  h.eq(refs_after, refs_before, "refs unchanged (no writes to refs/heads or refs/tags)")
  h.eq(head_after, head_before, "HEAD unchanged")

  -- Verify the fetch actually ran (separately from "non-destructive"):
  -- FETCH_HEAD now points at the fetched branch tip.
  h.not_nil(vim.uv.fs_stat(fetch_head_path),
    "FETCH_HEAD written by thaw (proves fetch ran)")
  local fh = vim.system({ "git", "-C", clone_path, "rev-parse", "FETCH_HEAD" },
                        { text = true }):wait().stdout or ""
  h.eq(fh:match("^([0-9a-f]+)"), HASH2, "FETCH_HEAD points at fetched tip")

  vim.fn.delete(clone_path,   "rf")
  vim.fn.delete(isolated_bare, "rf")
end

h.suite("thaw clone_path: rejected when path missing")
do
  reset_all()
  icebox.setup({})
  local got = icebox.thaw({
    clone_path = "/nonexistent/path/for/icebox/test",
    branch     = "main",
  })
  h.eq(got, icebox.ZERO_HASH, "nonexistent clone_path yields zero hash")
end

h.suite("thaw signature: single-table form uses opts.url")
do
  reset_all()
  icebox.setup({ cooldown_days = 0 })
  local got = icebox.thaw({
    url                = repo_url,
    branch             = "main",
  })
  h.eq(got, HASH2, "thaw({url=..., ...}) → single-table form uses opts.url")
end

h.suite("thaw signature: only three call shapes are accepted")
do
  reset_all()
  icebox.setup({})

  -- nil first argument (previously silently accepted) is now a parse error.
  local got = icebox.thaw(nil, { url = repo_url, branch = "main" })
  h.eq(got, icebox.ZERO_HASH, "thaw(nil, opts) → parse error → zero hash")

  -- Two tables → parse error.
  got = icebox.thaw({ url = repo_url }, { branch = "main" })
  h.eq(got, icebox.ZERO_HASH, "thaw(opts, opts) → parse error → zero hash")

  -- Non-string, non-table first argument.
  got = icebox.thaw(42, { branch = "main" })
  h.eq(got, icebox.ZERO_HASH, "thaw(<number>, opts) → parse error → zero hash")

  -- Non-nil, non-table second argument.
  got = icebox.thaw(repo_url, "not-a-table")
  h.eq(got, icebox.ZERO_HASH, "thaw(url, <string>) → parse error → zero hash")

  -- No arguments at all.
  got = icebox.thaw()
  h.eq(got, icebox.ZERO_HASH, "thaw() → parse error → zero hash")
end

h.suite("thaw signature: absolute path URL (no file:// prefix)")
do
  -- Pass the fixture bare repo path directly as an absolute filesystem
  -- path; validate.url + normalize_url should accept it and the sync fetch
  -- path should resolve it through git without a file:// prefix.
  reset_all()
  icebox.setup({ cooldown_days = 0 })
  local got = icebox.thaw(fixture_dir .. "/repo.git", {
    branch             = "main",
  })
  h.eq(got, HASH2, "absolute-path URL resolves through the full thaw pipeline")
end

h.suite("thaw signature: opts with no URL source is an error")
do
  reset_all()
  icebox.setup({})
  local got = icebox.thaw({ branch = "main" })
  h.eq(got, icebox.ZERO_HASH, "table form without url or clone_path → zero hash")
end

h.suite("thaw signature: clone_path resolves URL from origin")
do
  reset_all()
  -- Build an isolated bare mirror so icebox's fetch on the resolved origin
  -- doesn't touch the shared fixture bare repo used by other tests.
  local isolated_bare = vim.fn.tempname() .. "-bare.git"
  vim.system({ "git", "clone", "--quiet", "--bare",
               fixture_dir .. "/repo.git", isolated_bare },
             { text = true }):wait()
  local clone_path = vim.fn.tempname() .. "-origin"
  vim.system({ "git", "clone", "--quiet", isolated_bare, clone_path },
             { text = true }):wait()

  icebox.setup({ cooldown_days = 0 })
  -- Do NOT pass any URL — the origin should supply it
  local got = icebox.thaw({
    clone_path         = clone_path,
    branch             = "main",
  })
  h.eq(got, HASH2, "URL resolved from clone_path origin")

  vim.fn.delete(clone_path,   "rf")
  vim.fn.delete(isolated_bare, "rf")
end

h.suite("thaw clone_path: default_branch is seeded from local refs")
do
  reset_all()
  local isolated_bare = vim.fn.tempname() .. "-bare.git"
  vim.system({ "git", "clone", "--quiet", "--bare",
               fixture_dir .. "/repo.git", isolated_bare },
             { text = true }):wait()
  local clone_path = vim.fn.tempname() .. "-db"
  vim.system({ "git", "clone", "--quiet", isolated_bare, clone_path },
             { text = true }):wait()

  icebox.setup({})
  icebox.thaw({
    clone_path         = clone_path,
    branch             = "main",
  })

  -- After a clone_path-based fetch, default_branch must be recorded in the
  -- store, seeded from clone_path's refs/remotes/origin/HEAD. Otherwise
  -- future keyless calls would fall back to ls-remote on every startup.
  local git = require("icebox.git")
  local origin = git.origin_url(clone_path)
  local store_data = store.read(origin)
  h.eq(store_data.default_branch, "main",
    "default_branch is populated from clone_path's origin/HEAD")

  vim.fn.delete(clone_path,    "rf")
  vim.fn.delete(isolated_bare, "rf")
end

h.suite("thaw clone_path: empty store + no key → zero hash + bg probe")
do
  -- Drain any pending bg fetches from prior suites so their lock/state
  -- doesn't race with this suite's assertion on the origin URL.
  vim.wait(2000, function() return false end, 20)
  reset_all()

  local isolated_bare = vim.fn.tempname() .. "-bare.git"
  vim.system({ "git", "clone", "--quiet", "--bare",
               fixture_dir .. "/repo.git", isolated_bare },
             { text = true }):wait()
  local clone_path = vim.fn.tempname() .. "-keyless"
  vim.system({ "git", "clone", "--quiet", isolated_bare, clone_path },
             { text = true }):wait()

  -- Keyless call on an empty store triggers the fallback sync fetch:
  -- default_branch and tags are populated from the clone_path's origin.
  -- The returned hash is ZERO_HASH here because every just-fetched tag is
  -- still uncooled under the default 7-day cooldown.
  icebox.setup({})
  local got = icebox.thaw({ clone_path = clone_path })
  h.eq(got, icebox.ZERO_HASH, "keyless empty-store clone_path returns zero hash")

  local git = require("icebox.git")
  local origin = git.origin_url(clone_path)
  local data = store.read(origin)
  h.eq(data.default_branch, "main",
    "fallback sync fetch seeded default_branch from clone_path origin")

  vim.fn.delete(clone_path,    "rf")
  vim.fn.delete(isolated_bare, "rf")
end

h.suite("thaw signature: clone_path origin missing → error")
do
  reset_all()
  -- Init a fresh repo with no origin
  local clone_path = vim.fn.tempname() .. "-no-origin"
  vim.fn.mkdir(clone_path, "p")
  vim.system({ "git", "-C", clone_path, "init", "-q" }, { text = true }):wait()

  icebox.setup({})
  local got = icebox.thaw({
    clone_path = clone_path,
    branch     = "main",
  })
  h.eq(got, icebox.ZERO_HASH, "no origin in clone_path → zero hash")

  vim.fn.delete(clone_path, "rf")
end

h.suite("thaw signature: url sources are mutually exclusive")
do
  reset_all()
  -- Build an isolated clone so `clone_path` can be paired with each other source.
  local isolated_bare = vim.fn.tempname() .. "-bare.git"
  vim.system({ "git", "clone", "--quiet", "--bare",
               fixture_dir .. "/repo.git", isolated_bare },
             { text = true }):wait()
  local clone_path = vim.fn.tempname() .. "-excl"
  vim.system({ "git", "clone", "--quiet", isolated_bare, clone_path },
             { text = true }):wait()

  icebox.setup({})

  -- url arg + opts.url
  local got = icebox.thaw(repo_url, { url = repo_url, branch = "main" })
  h.eq(got, icebox.ZERO_HASH, "url arg + opts.url → zero hash")

  -- url arg + opts.clone_path
  got = icebox.thaw(repo_url, { clone_path = clone_path, branch = "main" })
  h.eq(got, icebox.ZERO_HASH, "url arg + opts.clone_path → zero hash")

  -- opts.url + opts.clone_path
  got = icebox.thaw({ url = repo_url, clone_path = clone_path, branch = "main" })
  h.eq(got, icebox.ZERO_HASH, "opts.url + opts.clone_path → zero hash")

  -- All three at once
  got = icebox.thaw(repo_url, { url = repo_url, clone_path = clone_path, branch = "main" })
  h.eq(got, icebox.ZERO_HASH, "all three sources → zero hash")

  vim.fn.delete(clone_path,    "rf")
  vim.fn.delete(isolated_bare, "rf")
end

-- ─── probe fallback (fetch_default) ──────────────────────────────────────────

-- Build an isolated bare repo that has NO tags. Used by the probe-fallback
-- suites below to exercise the branch-clone fallback when ls-remote finds no
-- semver tags upstream.
local function build_tagless_bare()
  local work_dir = vim.fn.tempname() .. "-tagless-work"
  local bare_dir = vim.fn.tempname() .. "-tagless.git"
  vim.fn.mkdir(work_dir, "p")
  vim.system({ "git", "-C", work_dir, "init", "-q", "-b", "main" },
             { text = true }):wait()
  vim.system({ "git", "-C", work_dir, "config", "user.email", "test@icebox" },
             { text = true }):wait()
  vim.system({ "git", "-C", work_dir, "config", "user.name", "Test" },
             { text = true }):wait()
  local f = io.open(work_dir .. "/file.txt", "w"); f:write("hi\n"); f:close()
  vim.system({ "git", "-C", work_dir, "add", "file.txt" }, { text = true }):wait()
  vim.system({ "git", "-C", work_dir, "commit", "-q", "-m", "c1" },
             { env = { GIT_AUTHOR_DATE = "2024-01-01T00:00:00+00:00",
                       GIT_COMMITTER_DATE = "2024-01-01T00:00:00+00:00",
                       PATH = vim.env.PATH },
               text = true }):wait()
  vim.system({ "git", "clone", "-q", "--bare", work_dir, bare_dir },
             { text = true }):wait()
  vim.fn.delete(work_dir, "rf")
  return bare_dir
end

h.suite("thaw probe fallback: tagless upstream populates branch history in one pass")
do
  vim.wait(2000, function() return false end, 20)
  reset_all()

  local tagless_bare = build_tagless_bare()
  local tagless_url  = "file://" .. tagless_bare

  icebox.setup({})
  local got = icebox.thaw(tagless_url)
  h.eq(got, icebox.ZERO_HASH,
    "first keyless call on empty store returns zero hash")

  -- After the bg fetch completes, both default_branch and the branch commit
  -- history should be populated in a single pass (probe fallback: ls-remote
  -- discovers there are no semver tags, then branch-fetches default_branch).
  local settled = vim.wait(5000, function()
    local d = store.read(tagless_url)
    return d.default_branch == "main"
       and d.branches["main"]
       and #d.branches["main"] >= 1
  end, 20)
  h.is_true(settled, "probe fallback populated default_branch + branches in one pass")

  local d = store.read(tagless_url)
  h.eq(d.default_branch, "main",           "default_branch populated")
  h.is_true(#d.branches["main"] >= 1,      "branches.main has at least one commit")
  h.is_true(next(d.tags) == nil,           "tags remain empty for tagless upstream")

  vim.fn.delete(tagless_bare, "rf")
end

h.suite("thaw probe fallback: upstream with tags stays on ls-remote-only")
do
  vim.wait(2000, function() return false end, 20)
  reset_all()

  icebox.setup({})
  local got = icebox.thaw(repo_url)
  h.eq(got, icebox.ZERO_HASH,
    "first keyless call on empty store returns zero hash")

  -- Fixture repo has semver tags, so fetch_default_async must NOT follow
  -- through with a branch clone; only tags + default_branch land in the store.
  local settled = vim.wait(5000, function()
    local d = store.read(repo_url)
    return next(d.tags) ~= nil
  end, 20)
  h.is_true(settled, "tags populated within timeout")

  local d = store.read(repo_url)
  h.is_true(d.tags["v1.0.0"] ~= nil,       "tags include v1.0.0")
  h.is_true(next(d.branches) == nil,
    "branches remain empty (branch clone skipped when tags exist)")
end

h.suite("thaw keyless bg_fetch: newly added upstream tags are picked up")
do
  vim.wait(2000, function() return false end, 20)
  reset_all()

  -- Start with a tagless upstream so probe fallback populates the branch route.
  local mutable_bare = build_tagless_bare()
  local mutable_url  = "file://" .. mutable_bare

  icebox.setup({})
  icebox.thaw(mutable_url)  -- probe fallback populates default_branch + main

  local branch_ready = vim.wait(5000, function()
    local d = store.read(mutable_url)
    return d.branches["main"] and #d.branches["main"] >= 1
  end, 20)
  h.is_true(branch_ready, "branch history populated by probe fallback")

  -- Now the upstream sprouts a new semver tag out-of-band.
  vim.system({ "git", "-C", mutable_bare, "tag", "v3.0.0" },
             { text = true }):wait()

  -- Second thaw call is still keyless, so initial_fetched for the fallback
  -- route ("default") is already set → the sync fetch is skipped and
  -- fetch_default_async runs in the background, re-running ls-remote and
  -- catching the new tag.
  icebox.thaw(mutable_url)
  local tag_seen = vim.wait(5000, function()
    return store.read(mutable_url).tags["v3.0.0"] ~= nil
  end, 20)
  h.is_true(tag_seen, "keyless bg_fetch surfaced the newly added tag")

  vim.fn.delete(mutable_bare, "rf")
end

-- ─── trust_initial_pin behaviour ────────────────────────────────────────────

h.suite("trust_initial_pin: pin recorded on first thaw when enabled")
do
  reset_all()
  icebox.setup({})

  local got = icebox.thaw(repo_url, {
    branch             = "main",
    trust_initial_pin  = true,
  })
  -- With cooldown_days=7 (default) all just-fetched commits are uncooled,
  -- so picker.pick would normally return nil. trust_initial_pin=true records
  -- candidates[1] (HASH2) as the initial pin and picker returns it as a
  -- bypass hash.
  h.eq(got, HASH2, "trust_initial_pin returns candidate[1] on first thaw")

  local data = store.read(repo_url)
  h.eq(store.get_initial_pin(data, "branch:main"), HASH2,
    "initial_pin persisted to store")
end

h.suite("trust_initial_pin: subsequent thaw reuses the recorded pin")
do
  reset_all()
  icebox.setup({})

  -- First thaw: record the pin.
  icebox.thaw(repo_url, { branch = "main", trust_initial_pin = true })

  -- Wait for any bg fetches to settle so the second call has a stable store.
  vim.wait(2000, function() return false end, 20)

  -- Second thaw with the same opts: initial_pin already exists, so it is
  -- reused as a bypass hash even though nothing is cooled yet.
  local got = icebox.thaw(repo_url, { branch = "main", trust_initial_pin = true })
  h.eq(got, HASH2, "second thaw returns the same initial_pin")
end

h.suite("trust_initial_pin=false: pin is not recorded but sync fetch still runs")
do
  reset_all()
  icebox.setup({})

  local got = icebox.thaw(repo_url, { branch = "main" })
  h.eq(got, icebox.ZERO_HASH,
    "no bypass hash → uncooled commits produce ZERO_HASH")

  local data = store.read(repo_url)
  h.is_nil(store.get_initial_pin(data, "branch:main"),
    "initial_pin not written when trust_initial_pin is off")
  h.is_true(store.is_initial_fetched(data, "branch:main"),
    "initial_fetched still marked (sync fetch ran)")
  h.is_true(#data.branches["main"] >= 1,
    "branch history populated by the sync fetch")
end

h.suite("trust_initial_pin: switching branch records a fresh pin under a new key")
do
  reset_all()
  icebox.setup({})

  -- First thaw for branch main.
  icebox.thaw(repo_url, { branch = "main", trust_initial_pin = true })

  local data = store.read(repo_url)
  h.eq(store.get_initial_pin(data, "branch:main"), HASH2,
    "initial_pin for main recorded")

  -- Same URL, different branch → different pin_key → separate sync fetch and
  -- separate initial_pin entry. The fixture only has main, so a fetch on
  -- develop will fail; use a version request instead which uses the fetched
  -- tags to build the candidate set.
  vim.wait(2000, function() return false end, 20)
  local got = icebox.thaw(repo_url, {
    version            = "^1.0.0",
    trust_initial_pin  = true,
  })
  h.is_true(got ~= icebox.ZERO_HASH,
    "version route returns a candidate via initial_pin")

  local d2 = store.read(repo_url)
  h.not_nil(store.get_initial_pin(d2, "version:^1.0.0"),
    "initial_pin under version pin_key recorded independently")
  h.eq(store.get_initial_pin(d2, "branch:main"), HASH2,
    "the original branch pin is untouched")
end

h.suite("trust_initial_pin: no pin recorded when candidates are empty")
do
  reset_all()
  icebox.setup({})

  -- version = "^99.0.0" won't match any fixture tag → candidates empty →
  -- picker returns nil → thaw returns ZERO_HASH. No pin should be recorded.
  local got = icebox.thaw(repo_url, {
    version            = "^99.0.0",
    trust_initial_pin  = true,
  })
  h.eq(got, icebox.ZERO_HASH,
    "empty candidate set with trust_initial_pin → ZERO_HASH")

  local data = store.read(repo_url)
  h.is_nil(store.get_initial_pin(data, "version:^99.0.0"),
    "initial_pin not recorded when candidate set is empty")
end

h.suite("thaw: trusted_commit is forwarded to picker")
do
  reset_all()
  icebox.setup({ cooldown_days = 7 })

  -- Seed a store with a recent (uncooled) commit on main + mark the route
  -- as already sync-fetched so thaw() skips step 1/2 and lands directly in
  -- the resolve pipeline. picker would return nil without trusted_commit
  -- because HASH2 is not cooled; asserting HASH2 is returned proves the
  -- opt made it through init.lua to picker.pick.
  local data = store.read(repo_url)
  data.fetched_at[HASH2] = os.time() - 3600  -- recent → not cooled
  data.branches["main"]  = { HASH2 }
  store.mark_initial_fetched(data, "branch:main")
  store.write(repo_url, data)

  local got = icebox.thaw(repo_url, {
    branch         = "main",
    trusted_commit = HASH2,
  })
  h.eq(got, HASH2, "trusted_commit forwarded to picker → returned as bypass")

  -- Sanity check: without trusted_commit the same store yields ZERO_HASH
  -- because HASH2 is uncooled and no bypass hash is in the candidate set.
  got = icebox.thaw(repo_url, { branch = "main" })
  h.eq(got, icebox.ZERO_HASH, "no trusted_commit → cooldown gates the commit")
end

h.summary()
