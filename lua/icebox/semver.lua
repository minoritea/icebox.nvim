local M = {}

-- Parse a version string like "1.2.3" or "v1.2.3".
-- Returns { major, minor, patch } or nil.
local function parse_version(s)
  s = s:gsub("^v", "")
  local major, minor, patch = s:match("^(%d+)%.(%d+)%.(%d+)$")
  if major then
    return { tonumber(major), tonumber(minor), tonumber(patch) }
  end
  -- Allow "1.2" as "1.2.0"
  major, minor = s:match("^(%d+)%.(%d+)$")
  if major then
    return { tonumber(major), tonumber(minor), 0 }
  end
  -- Allow "1" as "1.0.0"
  major = s:match("^(%d+)$")
  if major then
    return { tonumber(major), 0, 0 }
  end
  return nil
end

-- Compare two version tables. Returns -1, 0, or 1.
local function cmp(a, b)
  for i = 1, 3 do
    if a[i] < b[i] then return -1 end
    if a[i] > b[i] then return 1 end
  end
  return 0
end

-- Parse a range string. Returns a predicate function(version_table) -> bool, or nil + err.
-- Supported: "1.2.3", "^1.2.3", "~1.2.3", ">=1.2.3", ">1.2.3", "<=1.2.3", "<1.2.3"
function M.parse_range(s)
  if type(s) ~= "string" then
    return nil, "version range must be a string"
  end
  s = s:match("^%s*(.-)%s*$")  -- trim

  -- ^1.2.3 : >=1.2.3, <2.0.0
  local base = s:match("^%^(.+)$")
  if base then
    local v = parse_version(base)
    if not v then return nil, "invalid version in '^" .. base .. "'" end
    local lo = v
    local hi = { v[1] + 1, 0, 0 }
    return function(ver) return cmp(ver, lo) >= 0 and cmp(ver, hi) < 0 end
  end

  -- ~1.2.3 : >=1.2.3, <1.3.0
  base = s:match("^~(.+)$")
  if base then
    local v = parse_version(base)
    if not v then return nil, "invalid version in '~" .. base .. "'" end
    local lo = v
    local hi = { v[1], v[2] + 1, 0 }
    return function(ver) return cmp(ver, lo) >= 0 and cmp(ver, hi) < 0 end
  end

  -- >=, >, <=, <
  local op, ver_s = s:match("^(>=?)(.+)$")
  if not op then
    op, ver_s = s:match("^(<=?)(.+)$")
  end
  if op then
    local v = parse_version(ver_s)
    if not v then return nil, "invalid version in '" .. s .. "'" end
    if op == ">=" then
      return function(ver) return cmp(ver, v) >= 0 end
    elseif op == ">" then
      return function(ver) return cmp(ver, v) > 0 end
    elseif op == "<=" then
      return function(ver) return cmp(ver, v) <= 0 end
    elseif op == "<" then
      return function(ver) return cmp(ver, v) < 0 end
    end
  end

  -- exact: "1.2.3"
  local v = parse_version(s)
  if v then
    return function(ver) return cmp(ver, v) == 0 end
  end

  return nil, "cannot parse version range: '" .. s .. "'"
end

-- Returns true if tag_a > tag_b (semver comparison).
function M.gt(tag_a, tag_b)
  local a = parse_version(tag_a)
  local b = parse_version(tag_b)
  if not a or not b then return false end
  return cmp(a, b) > 0
end

-- Returns true if tag_name is a semver tag (with or without leading "v").
function M.is_semver_tag(tag_name)
  return parse_version(tag_name) ~= nil
end

return M
