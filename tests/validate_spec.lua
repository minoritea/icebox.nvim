local h        = require("helpers")
local validate = require("icebox.validate")

h.suite("validate.url")
do
  local ok, _  = validate.url("https://github.com/user/repo")
  h.is_true(ok, "https url")

  ok, _ = validate.url("git@github.com:user/repo.git")
  h.is_true(ok, "git@ ssh shorthand")

  ok, _ = validate.url("file:///home/user/repo")
  h.is_true(ok, "file url")

  ok, _ = validate.url("ftp://example.com/repo")
  h.is_false(ok, "ftp rejected")

  ok, _ = validate.url("https://example.com/\0repo")
  h.is_false(ok, "null byte rejected")

  ok, _ = validate.url(nil)
  h.is_false(ok, "nil rejected")

  ok, _ = validate.url("~/foo")
  h.is_false(ok, "~-prefixed url rejected")
end

h.suite("validate.branch")
do
  local ok, _ = validate.branch("main")
  h.is_true(ok, "simple branch")

  ok, _ = validate.branch("feature/my-feature")
  h.is_true(ok, "slash branch")

  ok, _ = validate.branch("--bad")
  h.is_false(ok, "leading -- rejected")

  ok, _ = validate.branch("a..b")
  h.is_false(ok, "dotdot rejected")

  ok, _ = validate.branch("bad branch")
  h.is_false(ok, "space rejected")
end

h.suite("validate.commit_hash")
do
  local ok, _ = validate.commit_hash("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
  h.is_true(ok, "valid hash")

  ok, _ = validate.commit_hash("0000000000000000000000000000000000000000")
  h.is_true(ok, "zero hash")

  ok, _ = validate.commit_hash("A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2")
  h.is_false(ok, "uppercase rejected")

  ok, _ = validate.commit_hash("abc123")
  h.is_false(ok, "short hash rejected")
end

h.suite("validate.opts")
do
  local opts, err = validate.opts({ branch = "main" })
  h.not_nil(opts, "branch opts ok")

  opts, err = validate.opts({ version = "^1.0.0" })
  h.not_nil(opts, "version opts ok")

  opts, err = validate.opts({ branch = "main", version = "^1.0.0" })
  h.is_nil(opts, "two keys rejected")

  opts, err = validate.opts({})
  h.not_nil(opts, "empty opts ok (default resolution)")

  opts, err = validate.opts({ trusted_commit = "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ" })
  h.is_nil(opts, "invalid trusted_commit rejected")
end

h.suite("validate.opts overrides")
do
  local opts, _ = validate.opts({ branch = "main", cooldown_days = 14 })
  h.not_nil(opts, "cooldown_days=14 accepted")
  h.eq(opts and opts.cooldown_days, 14, "cooldown_days preserved")

  opts, _ = validate.opts({ branch = "main", cooldown_days = -1 })
  h.is_nil(opts, "negative cooldown_days rejected")

  opts, _ = validate.opts({ branch = "main", cooldown_days = 1.5 })
  h.is_nil(opts, "fractional cooldown_days rejected")

  opts, _ = validate.opts({ branch = "main", trust_on_first_use = true })
  h.not_nil(opts, "trust_on_first_use=true accepted")
  h.eq(opts and opts.trust_on_first_use, true, "trust_on_first_use preserved")

  opts, _ = validate.opts({ branch = "main", trust_on_first_use = "yes" })
  h.is_nil(opts, "non-boolean trust_on_first_use rejected")

  opts, _ = validate.opts({ branch = "main", branch_commits_per_fetch = 10 })
  h.not_nil(opts, "branch_commits_per_fetch=10 accepted")
  h.eq(opts and opts.branch_commits_per_fetch, 10, "branch_commits_per_fetch preserved")

  opts, _ = validate.opts({ branch = "main", branch_commits_per_fetch = 0 })
  h.is_nil(opts, "branch_commits_per_fetch=0 rejected")
end

h.suite("validate.opts clone_path")
do
  local opts, _ = validate.opts({ branch = "main", clone_path = "/nonexistent/path" })
  h.is_nil(opts, "nonexistent clone_path rejected")

  opts, _ = validate.opts({ branch = "main", clone_path = "" })
  h.is_nil(opts, "empty clone_path rejected")

  opts, _ = validate.opts({ branch = "main", clone_path = "/tmp\0bad" })
  h.is_nil(opts, "null byte clone_path rejected")

  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  opts, _ = validate.opts({ branch = "main", clone_path = tmp })
  h.not_nil(opts, "existing directory accepted")
  h.eq(opts and opts.clone_path, tmp, "clone_path expanded and preserved")
  vim.fn.delete(tmp, "rf")
end

h.summary()
