local M = {}

local ALLOWED_SCHEMES = {
  ["https"] = true,
  ["http"] = true,
  ["ssh"] = true,
  ["git"] = true,
  ["git+ssh"] = true,
  ["file"] = true,
}

function M.url(url)
  if type(url) ~= "string" then
    return false, "url must be a string"
  end
  if #url > 2048 then
    return false, "url too long (max 2048)"
  end
  if url:find("\0") or url:find("\n") or url:find("\t") or url:find("\r") then
    return false, "url contains invalid characters"
  end
  local scheme = url:match("^([a-zA-Z][a-zA-Z0-9+%-.]*)://")
  if not scheme then
    -- git@host:path style (ssh shorthand)
    if url:match("^[a-zA-Z0-9_.%-]+@[a-zA-Z0-9_.%-]+:.+") then
      return true
    end
    return false, "url missing scheme"
  end
  if not ALLOWED_SCHEMES[scheme:lower()] then
    return false, "url scheme not allowed: " .. scheme
  end
  return true
end

function M.branch(name)
  if type(name) ~= "string" then
    return false, "branch must be a string"
  end
  if name:find("\0") or name:find("\n") or name:find("\r") then
    return false, "branch contains invalid characters"
  end
  if name:find("%.%.") then
    return false, "branch contains '..'"
  end
  if name:sub(1, 2) == "--" then
    return false, "branch must not start with '--'"
  end
  if not name:match("^[a-zA-Z0-9%.%-%_/]+$") then
    return false, "branch contains invalid characters"
  end
  return true
end

function M.tag(name)
  if type(name) ~= "string" then
    return false, "tag must be a string"
  end
  if name:find("\0") or name:find("\n") or name:find("\r") then
    return false, "tag contains invalid characters"
  end
  if name:find("%.%.") then
    return false, "tag contains '..'"
  end
  if name:sub(1, 2) == "--" then
    return false, "tag must not start with '--'"
  end
  if not name:match("^[a-zA-Z0-9%.%-%_/]+$") then
    return false, "tag contains invalid characters"
  end
  return true
end

function M.commit_hash(hash)
  if type(hash) ~= "string" then
    return false, "commit hash must be a string"
  end
  if not hash:match("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") then
    return false, "commit hash must be 40 lowercase hex characters"
  end
  return true
end

-- Parse and validate opts table. Returns resolved opts or nil + error message.
-- Resolved opts has exactly one of: branch, tag, version, commit.
function M.opts(opts)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    return nil, "opts must be a table"
  end

  local keys = { "branch", "tag", "version", "commit" }
  local found = {}
  for _, k in ipairs(keys) do
    if opts[k] ~= nil then
      found[#found + 1] = k
    end
  end

  if #found > 1 then
    return nil, "opts: only one of branch/tag/version/commit may be specified, got: " .. table.concat(found, ", ")
  end

  local kind = found[1]  -- may be nil (default resolution handled by caller)

  if kind == "branch" then
    local ok, err = M.branch(opts.branch)
    if not ok then return nil, "opts.branch: " .. err end
  elseif kind == "tag" then
    local ok, err = M.tag(opts.tag)
    if not ok then return nil, "opts.tag: " .. err end
  elseif kind == "version" then
    -- semver parsing is done by semver.lua; just check it's a string here
    if type(opts.version) ~= "string" then
      return nil, "opts.version must be a string"
    end
  elseif kind == "commit" then
    local ok, err = M.commit_hash(opts.commit)
    if not ok then return nil, "opts.commit: " .. err end
  end

  if opts.trusted_commit ~= nil then
    local ok, err = M.commit_hash(opts.trusted_commit)
    if not ok then return nil, "opts.trusted_commit: " .. err end
  end

  return opts
end

return M
