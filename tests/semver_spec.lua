local h      = require("helpers")
local semver = require("icebox.semver")

h.suite("semver.parse_range / matches")
do
  h.is_true(semver.matches("v1.2.3", "1.2.3"),   "exact match with v prefix")
  h.is_true(semver.matches("1.2.3",  "1.2.3"),   "exact match no prefix")
  h.is_false(semver.matches("1.2.4", "1.2.3"),   "exact mismatch")

  h.is_true(semver.matches("v1.2.3", "^1.0.0"),  "caret: patch higher ok")
  h.is_true(semver.matches("v1.9.9", "^1.0.0"),  "caret: minor higher ok")
  h.is_false(semver.matches("v2.0.0", "^1.0.0"), "caret: major higher rejected")
  h.is_false(semver.matches("v0.9.9", "^1.0.0"), "caret: below lower bound rejected")

  h.is_true(semver.matches("v1.2.5", "~1.2.3"),  "tilde: patch higher ok")
  h.is_false(semver.matches("v1.3.0", "~1.2.3"), "tilde: minor bump rejected")

  h.is_true(semver.matches("v2.0.0", ">=1.0.0"), "gte ok")
  h.is_false(semver.matches("v0.9.0",">=1.0.0"), "gte: below rejected")

  h.is_true(semver.matches("v1.0.1", ">1.0.0"),  "gt ok")
  h.is_false(semver.matches("v1.0.0",">1.0.0"),  "gt: equal rejected")

  h.is_true(semver.matches("v0.9.9", "<1.0.0"),  "lt ok")
  h.is_false(semver.matches("v1.0.0","<1.0.0"),  "lt: equal rejected")

  h.is_true(semver.matches("v1.0.0", "<=1.0.0"), "lte equal ok")
  h.is_false(semver.matches("v1.0.1","<=1.0.0"), "lte: above rejected")

  h.is_true(semver.matches("v0.0.1", ">=0.0.0"), ">=0.0.0 matches any")
end

h.suite("semver.gt")
do
  h.is_true(semver.gt("v1.2.3", "v1.2.2"),  "patch gt")
  h.is_true(semver.gt("v2.0.0", "v1.9.9"),  "major gt")
  h.is_false(semver.gt("v1.0.0","v1.0.0"),  "equal not gt")
  h.is_false(semver.gt("v1.0.0","v1.0.1"),  "less not gt")
end

h.suite("semver.is_semver_tag")
do
  h.is_true(semver.is_semver_tag("v1.2.3"),  "v-prefixed")
  h.is_true(semver.is_semver_tag("1.2.3"),   "no prefix")
  h.is_false(semver.is_semver_tag("stable"), "non-semver")
  h.is_false(semver.is_semver_tag("latest"), "non-semver 2")
end

h.suite("semver.is_range")
do
  h.is_true(semver.is_range("^1.0.0"),   "caret")
  h.is_true(semver.is_range(">=1.0.0"),  "gte")
  h.is_true(semver.is_range("1.2.3"),    "bare version")
  h.is_false(semver.is_range("main"),    "branch name")
  h.is_false(semver.is_range("feature/x"), "slash branch")
end

h.summary()
