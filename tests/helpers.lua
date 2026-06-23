local M = {}

local pass_count = 0
local fail_count = 0
local current_suite = ""

function M.suite(name)
  current_suite = name
  print("\n[" .. name .. "]")
end

function M.eq(got, expected, label)
  label = label or ""
  if got == expected then
    pass_count = pass_count + 1
    print("  PASS " .. label)
  else
    fail_count = fail_count + 1
    print("  FAIL " .. label)
    print("    expected: " .. vim.inspect(expected))
    print("    got:      " .. vim.inspect(got))
  end
end

function M.is_true(cond, label)
  M.eq(not not cond, true, label)
end

function M.is_false(cond, label)
  M.eq(not not cond, false, label)
end

function M.is_nil(val, label)
  label = label or ""
  if val == nil then
    pass_count = pass_count + 1
    print("  PASS " .. label)
  else
    fail_count = fail_count + 1
    print("  FAIL " .. label .. " (expected nil, got " .. vim.inspect(val) .. ")")
  end
end

function M.not_nil(val, label)
  label = label or ""
  if val ~= nil then
    pass_count = pass_count + 1
    print("  PASS " .. label)
  else
    fail_count = fail_count + 1
    print("  FAIL " .. label .. " (expected non-nil, got nil)")
  end
end

function M.summary()
  print(string.format("\n%d passed, %d failed", pass_count, fail_count))
  if fail_count > 0 then
    vim.cmd("cquit 1")
  else
    vim.cmd("qall")
  end
end

return M
