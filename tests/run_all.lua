-- Run all spec files in sequence and exit with appropriate code.
local specs = {
  "tests/validate_spec.lua",
  "tests/semver_spec.lua",
  "tests/store_spec.lua",
  "tests/resolver_spec.lua",
}

-- Each spec calls h.summary() which exits; we need to run them as separate
-- nvim invocations from the shell runner instead.
-- This file is kept as documentation of the full suite order.
print("Use 'make test' to run all specs.")
vim.cmd("qall")
