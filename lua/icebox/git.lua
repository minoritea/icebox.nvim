local M = {}

local semver   = require("icebox.semver")
local validate = require("icebox.validate")

local CLONE_SAFETY_ARGS = {
  "--no-local",
  "--no-hardlinks",
  "-c", "core.hooksPath=/dev/null",
  "-c", "core.fsmonitor=false",
  "--filter=blob:none",
}

-- Parse "git ls-remote --symref" output (no ref filter → includes HEAD symref + all refs).
-- Returns { default_branch=string|nil, tags={ name=hash } }
local function parse_ls_remote_symref_tags(stdout)
  local result = { tags = {} }
  -- Collect ^{} derefs first: tag_name -> real commit hash
  local derefs = {}
  for line in stdout:gmatch("[^\n]+") do
    local hash, ref = line:match("^([0-9a-f]+)%s+(refs/tags/(.-)%^%{%})$")
    if hash and ref then
      local tag = line:match("refs/tags/(.-)%^%{%}$")
      if tag and validate.commit_hash(hash) then
        derefs[tag] = hash
      end
    end
  end

  for line in stdout:gmatch("[^\n]+") do
    -- symref line
    if line:match("^ref: refs/heads/") then
      result.default_branch = line:match("^ref: refs/heads/(.-)%s")
        or line:match("^ref: refs/heads/(.+)$")
    end
    -- tag line (skip ^{} lines)
    if not line:match("%^%{%}") then
      local hash, tag = line:match("^([0-9a-f]+)%s+refs/tags/(.+)$")
      if hash and tag and validate.commit_hash(hash) then
        -- Prefer deref hash if available (annotated tag)
        result.tags[tag] = derefs[tag] or hash
      end
    end
  end
  return result
end

-- Parse "git log --first-parent --format=%H" output.
-- Returns array of hashes in commitlog order (newest first).
local function parse_log(stdout)
  local hashes = {}
  for line in stdout:gmatch("[^\n]+") do
    local h = line:match("^([0-9a-f]+)$")
    if h and validate.commit_hash(h) then
      hashes[#hashes + 1] = h
    end
  end
  return hashes
end

-- Run a command synchronously. Returns { code, stdout, stderr }.
local function run_sync(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  return result
end

-- Create a unique temp directory under the system temp dir.
local function make_tmpdir()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, "p")
  return base
end

-- Recursively remove a directory tree (synchronous best-effort).
local function rmdir_rf(path)
  vim.fn.delete(path, "rf")
end

-- ─── Synchronous fetch (trust_on_first_use path) ─────────────────────────────

-- Fetch branch synchronously. Returns new_data table or nil + err.
function M.fetch_branch_sync(url, branch)
  local tmpdir = make_tmpdir()
  local clone_args = { "git", "clone", "--bare" }
  vim.list_extend(clone_args, CLONE_SAFETY_ARGS)
  if branch then
    vim.list_extend(clone_args, { "--branch", branch, "--single-branch" })
  end
  vim.list_extend(clone_args, { url, tmpdir })

  local r = run_sync(clone_args)
  if r.code ~= 0 then
    rmdir_rf(tmpdir)
    return nil, "git clone failed: " .. (r.stderr or "")
  end

  -- Resolve default_branch from local symref
  local symref_r = run_sync({ "git", "-C", tmpdir, "symbolic-ref", "HEAD" })
  local default_branch = nil
  if symref_r.code == 0 then
    default_branch = symref_r.stdout:match("refs/heads/(.-)%s*$")
      or symref_r.stdout:match("refs/heads/(.+)$")
  end

  local log_r = run_sync({
    "git", "-C", tmpdir, "log", "--first-parent", "--format=%H", "HEAD"
  })
  rmdir_rf(tmpdir)

  if log_r.code ~= 0 then
    return nil, "git log failed: " .. (log_r.stderr or "")
  end

  local hashes = parse_log(log_r.stdout)
  local now    = os.time()
  local fetched_at = {}
  for _, h in ipairs(hashes) do
    fetched_at[h] = now
  end

  return {
    default_branch = default_branch,
    fetched_at     = fetched_at,
    branches       = { [branch or default_branch or "HEAD"] = hashes },
    tags           = {},
  }
end

-- Fetch tags synchronously (for tag/version opts). Returns new_data or nil + err.
function M.fetch_tags_sync(url)
  local r = run_sync({ "git", "ls-remote", "--symref", url })
  if r.code ~= 0 then
    return nil, "git ls-remote failed: " .. (r.stderr or "")
  end

  local parsed = parse_ls_remote_symref_tags(r.stdout)
  local now    = os.time()
  local fetched_at = {}
  for _, hash in pairs(parsed.tags) do
    fetched_at[hash] = now
  end

  return {
    default_branch = parsed.default_branch,
    fetched_at     = fetched_at,
    branches       = {},
    tags           = parsed.tags,
  }
end

-- ─── Asynchronous fetch (background) ─────────────────────────────────────────

-- Spawn a git command asynchronously. Calls callback(code, stdout, stderr) on exit.
local function spawn_async(cmd, callback)
  local stdout_chunks = {}
  local stderr_chunks = {}
  local stdout_pipe = vim.uv.new_pipe()
  local stderr_pipe = vim.uv.new_pipe()

  local exe = cmd[1]
  local args = {}
  for i = 2, #cmd do args[#args + 1] = cmd[i] end
  local handle
  handle = vim.uv.spawn(exe, {
    args   = args,
    stdio  = { nil, stdout_pipe, stderr_pipe },
  }, function(code, _signal)
    stdout_pipe:close()
    stderr_pipe:close()
    handle:close()
    vim.schedule(function()
      callback(code, table.concat(stdout_chunks), table.concat(stderr_chunks))
    end)
  end)

  if not handle then
    callback(1, "", "failed to spawn " .. exe)
    return
  end

  stdout_pipe:read_start(function(_err, data)
    if data then stdout_chunks[#stdout_chunks + 1] = data end
  end)
  stderr_pipe:read_start(function(_err, data)
    if data then stderr_chunks[#stderr_chunks + 1] = data end
  end)
end

-- Fetch a branch asynchronously.
-- on_done(new_data, err) is called on completion.
function M.fetch_branch_async(url, branch, on_done)
  local tmpdir = make_tmpdir()
  local clone_cmd = { "git", "clone", "--bare" }
  vim.list_extend(clone_cmd, CLONE_SAFETY_ARGS)
  if branch then
    vim.list_extend(clone_cmd, { "--branch", branch, "--single-branch" })
  end
  vim.list_extend(clone_cmd, { url, tmpdir })

  spawn_async(clone_cmd, function(code, _stdout, stderr)
    if code ~= 0 then
      rmdir_rf(tmpdir)
      on_done(nil, "git clone failed: " .. stderr)
      return
    end

    -- default_branch via local symbolic-ref (no network)
    local symref_r = run_sync({ "git", "-C", tmpdir, "symbolic-ref", "HEAD" })
    local default_branch = nil
    if symref_r.code == 0 then
      default_branch = symref_r.stdout:match("refs/heads/(.-)%s*$")
        or symref_r.stdout:match("refs/heads/(.+)$")
    end

    local log_cmd = {
      "git", "-C", tmpdir, "log", "--first-parent", "--format=%H", "HEAD"
    }
    spawn_async(log_cmd, function(log_code, log_stdout, log_stderr)
      rmdir_rf(tmpdir)
      if log_code ~= 0 then
        on_done(nil, "git log failed: " .. log_stderr)
        return
      end

      local hashes     = parse_log(log_stdout)
      local now        = os.time()
      local fetched_at = {}
      for _, h in ipairs(hashes) do
        fetched_at[h] = now
      end

      local branch_key = branch or default_branch or "HEAD"
      on_done({
        default_branch = default_branch,
        fetched_at     = fetched_at,
        branches       = { [branch_key] = hashes },
        tags           = {},
      }, nil)
    end)
  end)
end

-- Fetch tags asynchronously (covers tag + version opts, and default_branch).
-- on_done(new_data, err) is called on completion.
function M.fetch_tags_async(url, on_done)
  local cmd = { "git", "ls-remote", "--symref", url }
  spawn_async(cmd, function(code, stdout, stderr)
    if code ~= 0 then
      on_done(nil, "git ls-remote failed: " .. stderr)
      return
    end

    local parsed     = parse_ls_remote_symref_tags(stdout)
    local now        = os.time()
    local fetched_at = {}
    for _, hash in pairs(parsed.tags) do
      fetched_at[hash] = now
    end

    on_done({
      default_branch = parsed.default_branch,
      fetched_at     = fetched_at,
      branches       = {},
      tags           = parsed.tags,
    }, nil)
  end)
end

-- Fetch default_branch only via ls-remote --symref (async, used in BG when
-- opts is nil/default and trust_on_first_use=false).
function M.fetch_default_branch_async(url, on_done)
  M.fetch_tags_async(url, on_done)
end

return M
