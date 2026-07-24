local M = {}

local semver = require("icebox.semver")

M.ZERO_HASH = "0000000000000000000000000000000000000000"

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
  -- Reject `~`-prefixed paths in URL position. `~` has no meaning outside a
  -- shell, and icebox never expands it for URLs — callers must pass an
  -- already-expanded path (e.g. via vim.fn.expand()) if they want a local
  -- absolute path here.
  if url:sub(1, 1) == "~" then
    return false, "url must not start with '~'; expand it to an absolute path first"
  end
  -- Absolute local path (git accepts these directly as clone sources).
  if url:sub(1, 1) == "/" then
    return true
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

-- Validate and expand a clone_path.
--
-- A clone_path points to an EXISTING local clone of the upstream repo — one
-- that another tool (e.g. a plugin manager) already maintains. This is NOT
-- an icebox-owned cache: the directory must exist and be a git repository at
-- call time; icebox never creates, initializes, or clones into this path.
-- If the directory is missing, this function returns nil + error (which the
-- caller surfaces as vim.notify WARN + ZERO_HASH) — no auto-creation.
--
-- Trust boundary: the caller is responsible for choosing a trustworthy path.
-- icebox does not check whether the directory is a symlink, world-writable,
-- or under a "plausible" location, and does not audit `.git/config` contents.
-- A compromised clone (e.g. one whose origin has been repointed at an
-- attacker-controlled server) will cause icebox to fetch from that upstream.
-- Only pass paths owned by tools you already trust.
--
-- Returns the ~/tilde-expanded path on success, or nil + error message.
function M.clone_path(path)
  if type(path) ~= "string" then
    return nil, "clone_path must be a string"
  end
  if path == "" then
    return nil, "clone_path must not be empty"
  end
  if path:find("\0") or path:find("\n") or path:find("\t") or path:find("\r") then
    return nil, "clone_path contains invalid characters"
  end
  local expanded = vim.fn.expand(path)
  if type(expanded) ~= "string" or expanded == "" then
    return nil, "clone_path could not be expanded"
  end
  if vim.fn.isdirectory(expanded) ~= 1 then
    return nil, "clone_path directory not found: " .. expanded
  end
  return expanded
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
    local _, range_err = semver.parse_range(opts.version)
    if range_err then return nil, "opts.version: " .. range_err end
  elseif kind == "commit" then
    local ok, err = M.commit_hash(opts.commit)
    if not ok then return nil, "opts.commit: " .. err end
  end

  if opts.trusted_commit ~= nil then
    local ok, err = M.commit_hash(opts.trusted_commit)
    if not ok then return nil, "opts.trusted_commit: " .. err end
  end

  if opts.normalize ~= nil then
    if type(opts.normalize) ~= "function" then
      return nil, "opts.normalize: must be a function"
    end
  end

  if opts.cooldown_days ~= nil then
    if type(opts.cooldown_days) ~= "number"
      or opts.cooldown_days < 0
      or math.floor(opts.cooldown_days) ~= opts.cooldown_days then
      return nil, "opts.cooldown_days: must be a non-negative integer"
    end
  end

  if opts.trust_on_first_use ~= nil then
    if type(opts.trust_on_first_use) ~= "boolean" then
      return nil, "opts.trust_on_first_use: must be a boolean"
    end
  end

  if opts.branch_commits_per_fetch ~= nil then
    if type(opts.branch_commits_per_fetch) ~= "number"
      or opts.branch_commits_per_fetch < 1
      or math.floor(opts.branch_commits_per_fetch) ~= opts.branch_commits_per_fetch then
      return nil, "opts.branch_commits_per_fetch: must be a positive integer"
    end
  end

  if opts.clone_path ~= nil then
    local expanded, err = M.clone_path(opts.clone_path)
    if not expanded then return nil, "opts.clone_path: " .. err end
    opts.clone_path = expanded
  end

  -- opts.url is validated in init.thaw() after GitHub shorthand expansion.
  -- Only reject clearly-wrong types here.
  if opts.url ~= nil and type(opts.url) ~= "string" then
    return nil, "opts.url: must be a string"
  end

  return opts
end

return M
