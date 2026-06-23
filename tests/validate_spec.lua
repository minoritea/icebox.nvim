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

  opts, err = validate.opts({ branch = "main", tag = "v1.0.0" })
  h.is_nil(opts, "two keys rejected")

  opts, err = validate.opts({})
  h.not_nil(opts, "empty opts ok (default resolution)")

  opts, err = validate.opts({ trusted_commit = "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ" })
  h.is_nil(opts, "invalid trusted_commit rejected")
end

h.summary()
