local h      = require("helpers")
local semver = require("icebox.semver")

h.suite("semver.parse_range")
do
  local pred, err

  pred, err = semver.parse_range("1.2.3")
  h.is_nil(err, "exact: no error")
  h.is_true(pred({1,2,3}),  "exact match")
  h.is_false(pred({1,2,4}), "exact mismatch")

  pred = semver.parse_range("^1.0.0")
  h.is_true(pred({1,2,3}),  "caret: patch higher ok")
  h.is_true(pred({1,9,9}),  "caret: minor higher ok")
  h.is_false(pred({2,0,0}), "caret: major higher rejected")
  h.is_false(pred({0,9,9}), "caret: below lower bound rejected")

  pred = semver.parse_range("~1.2.3")
  h.is_true(pred({1,2,5}),  "tilde: patch higher ok")
  h.is_false(pred({1,3,0}), "tilde: minor bump rejected")

  pred = semver.parse_range(">=1.0.0")
  h.is_true(pred({2,0,0}),  "gte ok")
  h.is_false(pred({0,9,0}), "gte: below rejected")

  pred = semver.parse_range(">1.0.0")
  h.is_true(pred({1,0,1}),  "gt ok")
  h.is_false(pred({1,0,0}), "gt: equal rejected")

  pred = semver.parse_range("<1.0.0")
  h.is_true(pred({0,9,9}),  "lt ok")
  h.is_false(pred({1,0,0}), "lt: equal rejected")

  pred = semver.parse_range("<=1.0.0")
  h.is_true(pred({1,0,0}),  "lte equal ok")
  h.is_false(pred({1,0,1}), "lte: above rejected")

  pred = semver.parse_range(">=0.0.0")
  h.is_true(pred({0,0,1}),  ">=0.0.0 matches any")

  _, err = semver.parse_range("bogus")
  h.not_nil(err, "invalid range returns error")
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

h.summary()
