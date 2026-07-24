local M = {}

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

local function run_sync(cmd)
  return vim.system(cmd, { text = true }):wait()
end

-- Read the `origin` remote URL from a local repo. Returns url string or nil + err.
function M.origin_url(clone_path)
  local r = run_sync({ "git", "-C", clone_path, "remote", "get-url", "origin" })
  if r.code ~= 0 then
    return nil, "origin not set in clone_path: " .. (r.stderr or ""):gsub("%s+$", "")
  end
  local url = (r.stdout or ""):gsub("%s+$", "")
  if url == "" then
    return nil, "origin URL is empty"
  end
  return url
end

local function run_async(cmd, on_done)
  vim.system(cmd, { text = true }, function(r)
    vim.schedule(function() on_done(r) end)
  end)
end

local function rmdir_rf(path)
  vim.fn.delete(path, "rf")
end

-- Build a git-log command that caps the number of commits returned.
local function build_log_cmd(dir, limit, ref)
  local cmd = { "git", "-C", dir, "log", "--first-parent", "--format=%H" }
  if limit then
    vim.list_extend(cmd, { "-n", tostring(limit) })
  end
  cmd[#cmd + 1] = ref or "HEAD"
  return cmd
end

-- Build a bare-clone command targeting `dest`.
-- The `--` before `url` ensures git never parses a URL starting with `-`
-- as an option even if validate.url's allow-list is ever relaxed.
local function build_clone_cmd(url, branch, dest)
  local cmd = { "git", "clone", "--bare" }
  vim.list_extend(cmd, CLONE_SAFETY_ARGS)
  if branch then
    vim.list_extend(cmd, { "--branch", branch, "--single-branch" })
  end
  vim.list_extend(cmd, { "--", url, dest })
  return cmd
end

-- Check whether `dir` is a healthy bare repo. `rev-parse --git-dir` alone is
-- unsafe because git walks up the directory tree looking for a `.git`, so a
-- junk directory nested inside another repo would falsely pass. Require the
-- resolved git-dir to be `dir` itself.
local function is_healthy_repo_sync(dir)
  if vim.fn.isdirectory(dir) ~= 1 then return false end
  local r = run_sync({
    "git", "-C", dir,
    "-c", "safe.directory=*",
    "rev-parse", "--git-dir",
  })
  if r.code ~= 0 then return false end
  local out = (r.stdout or ""):gsub("%s+$", "")
  return out == "." or out == dir
end

-- Parse the stdout of `git symbolic-ref <ref>` into a plain branch name.
-- Handles both `refs/heads/<name>` (from a bare/fresh HEAD) and
-- `refs/remotes/<remote>/<name>` (from `refs/remotes/origin/HEAD`).
local function parse_symref_stdout(stdout)
  return stdout:match("refs/heads/(.-)%s*$")
    or stdout:match("refs/heads/(.+)$")
    or stdout:match("refs/remotes/[^/]+/(.-)%s*$")
    or stdout:match("refs/remotes/[^/]+/(.+)$")
end

-- Resolve a symbolic-ref to a branch name (sync). `ref` defaults to "HEAD",
-- which is what bare / freshly-cloned repos use. For non-bare user clones
-- (as with clone_path) pass "refs/remotes/origin/HEAD" instead so we track
-- the *origin's* default branch rather than whatever the user has checked
-- out locally.
local function read_default_branch_sync(dir, ref)
  local r = run_sync({ "git", "-C", dir, "symbolic-ref", ref or "HEAD" })
  if r.code ~= 0 then return nil end
  return parse_symref_stdout(r.stdout)
end

-- Ensure the bare repo at `cache_dir` is present and up-to-date for `branch`.
-- Returns the ref name to read history from, or nil + err.
--   - Fresh clone → "HEAD"
--   - Existing cache after fetch → "FETCH_HEAD"
-- If an existing cache passes the health check but the fetch itself fails
-- (e.g. origin URL changed, cache subtly corrupted between checks), the cache
-- is wiped and a fresh clone is attempted — mirroring the async path.
local function ensure_cache_sync(cache_dir, url, branch)
  if is_healthy_repo_sync(cache_dir) then
    local ref = branch and ("refs/heads/" .. branch) or "HEAD"
    local r = run_sync({ "git", "-C", cache_dir, "fetch", "origin", ref })
    if r.code == 0 then
      return "FETCH_HEAD"
    end
    -- Fall through to re-clone.
  end
  rmdir_rf(cache_dir)
  vim.fn.mkdir(vim.fn.fnamemodify(cache_dir, ":h"), "p")
  local r = run_sync(build_clone_cmd(url, branch, cache_dir))
  if r.code ~= 0 then
    return nil, "git clone failed: " .. (r.stderr or "")
  end
  return "HEAD"
end

-- Build a new_data table from a branch's commit hashes.
local function build_branch_data(hashes, branch_key, default_branch)
  local now = os.time()
  local fetched_at = {}
  for _, h in ipairs(hashes) do
    fetched_at[h] = now
  end
  return {
    default_branch = default_branch,
    fetched_at     = fetched_at,
    branches       = { [branch_key] = hashes },
    tags           = {},
  }
end

-- ─── Synchronous fetch (trust_on_first_use path) ─────────────────────────────

-- Fetch a branch history from `clone_path`, which is an EXISTING local clone
-- maintained by another tool (e.g. a plugin manager) — NOT an icebox cache.
-- Preconditions: the path exists and is a git repository (validate.clone_path
-- enforces this at the call site). This function never creates, initializes,
-- or clones into the path; a missing/broken directory is treated as an error.
-- The clone is used non-destructively: only FETCH_HEAD is updated, no local
-- refs or working tree state is touched.
local function fetch_branch_from_clone_sync(url, branch, limit, clone_path)
  local health = run_sync({ "git", "-C", clone_path, "rev-parse", "--git-dir" })
  if health.code ~= 0 then
    return nil, "clone_path is not a git repository: " .. clone_path
  end
  local fetch_cmd = { "git", "-C", clone_path, "fetch", "--no-tags", "--", url }
  if branch then fetch_cmd[#fetch_cmd + 1] = branch end
  local r = run_sync(fetch_cmd)
  if r.code ~= 0 then
    return nil, "git fetch failed: " .. (r.stderr or "")
  end
  local log_r = run_sync(build_log_cmd(clone_path, limit, "FETCH_HEAD"))
  if log_r.code ~= 0 then
    return nil, "git log failed: " .. (log_r.stderr or "")
  end
  local hashes = parse_log(log_r.stdout)
  -- Seed default_branch from the origin's tracked HEAD (best-effort).
  local default_branch = read_default_branch_sync(clone_path, "refs/remotes/origin/HEAD")
  return build_branch_data(hashes, branch or default_branch or "HEAD", default_branch)
end

-- Fetch branch synchronously. Returns new_data table or nil + err.
-- `limit` (optional number): cap on the number of commits returned.
-- `opts` MUST supply exactly one of:
--   opts.cache_dir   → icebox-owned persistent bare clone at this path.
--                      Created/re-cloned as needed.
--   opts.clone_path  → EXISTING externally-managed clone. Must exist at call
--                      time; icebox never creates it. Read-only fetch via
--                      FETCH_HEAD; no local refs are mutated.
function M.fetch_branch_sync(url, branch, limit, opts)
  if opts.clone_path then
    return fetch_branch_from_clone_sync(url, branch, limit, opts.clone_path)
  end

  local cache_dir = opts.cache_dir
  local ref, err = ensure_cache_sync(cache_dir, url, branch)
  if not ref then
    return nil, err
  end

  local default_branch = read_default_branch_sync(cache_dir)
  local log_r = run_sync(build_log_cmd(cache_dir, limit, ref))
  if log_r.code ~= 0 then
    return nil, "git log failed: " .. (log_r.stderr or "")
  end
  local hashes = parse_log(log_r.stdout)
  return build_branch_data(hashes, branch or default_branch or "HEAD", default_branch)
end

-- Fetch tags synchronously (for tag/version opts). Returns new_data or nil + err.
function M.fetch_tags_sync(url)
  local r = run_sync({ "git", "ls-remote", "--symref", "--", url })
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

-- Async counterpart of fetch_branch_from_clone_sync. Same contract:
-- `clone_path` is an EXISTING externally-managed clone; icebox never creates
-- or modifies it, and only reads history via FETCH_HEAD.
local function fetch_branch_from_clone_async(url, branch, limit, clone_path, on_done)
  run_async({ "git", "-C", clone_path, "rev-parse", "--git-dir" }, function(health)
    if health.code ~= 0 then
      on_done(nil, "clone_path is not a git repository: " .. clone_path)
      return
    end
    local fetch_cmd = { "git", "-C", clone_path, "fetch", "--no-tags", "--", url }
    if branch then fetch_cmd[#fetch_cmd + 1] = branch end
    run_async(fetch_cmd, function(fr)
      if fr.code ~= 0 then
        on_done(nil, "git fetch failed: " .. (fr.stderr or ""))
        return
      end
      run_async(build_log_cmd(clone_path, limit, "FETCH_HEAD"), function(lr)
        if lr.code ~= 0 then
          on_done(nil, "git log failed: " .. (lr.stderr or ""))
          return
        end
        -- Seed default_branch from the origin's tracked HEAD (best-effort).
        run_async({ "git", "-C", clone_path, "symbolic-ref",
                    "refs/remotes/origin/HEAD" }, function(sr)
          local default_branch = sr.code == 0
            and parse_symref_stdout(sr.stdout) or nil
          on_done(build_branch_data(parse_log(lr.stdout),
                                    branch or default_branch or "HEAD",
                                    default_branch), nil)
        end)
      end)
    end)
  end)
end

-- Complete branch fetch after the clone/fetch step finishes.
local function finish_branch_fetch_async(cache_dir, branch, limit, ref, on_done)
  run_async({ "git", "-C", cache_dir, "symbolic-ref", "HEAD" }, function(sr)
    local default_branch = sr.code == 0
      and parse_symref_stdout(sr.stdout) or nil
    run_async(build_log_cmd(cache_dir, limit, ref), function(lr)
      if lr.code ~= 0 then
        on_done(nil, "git log failed: " .. (lr.stderr or ""))
        return
      end
      local hashes = parse_log(lr.stdout)
      on_done(build_branch_data(hashes, branch or default_branch or "HEAD", default_branch), nil)
    end)
  end)
end

-- Fetch a branch asynchronously. `opts` mirrors the sync counterpart:
-- MUST supply exactly one of opts.cache_dir or opts.clone_path.
function M.fetch_branch_async(url, branch, limit, opts, on_done)
  if opts.clone_path then
    fetch_branch_from_clone_async(url, branch, limit, opts.clone_path, on_done)
    return
  end

  local cache_dir = opts.cache_dir

  local function do_clone()
    rmdir_rf(cache_dir)
    vim.fn.mkdir(vim.fn.fnamemodify(cache_dir, ":h"), "p")
    run_async(build_clone_cmd(url, branch, cache_dir), function(cr)
      if cr.code ~= 0 then
        on_done(nil, "git clone failed: " .. (cr.stderr or ""))
        return
      end
      finish_branch_fetch_async(cache_dir, branch, limit, "HEAD", on_done)
    end)
  end

  if is_healthy_repo_sync(cache_dir) then
    local ref = branch and ("refs/heads/" .. branch) or "HEAD"
    run_async({ "git", "-C", cache_dir, "fetch", "origin", ref }, function(fr)
      if fr.code ~= 0 then
        -- Fall back to re-clone on any fetch failure (covers stale/broken origin)
        do_clone()
        return
      end
      finish_branch_fetch_async(cache_dir, branch, limit, "FETCH_HEAD", on_done)
    end)
  else
    do_clone()
  end
end

-- Fetch tags asynchronously (covers tag + version opts, and default_branch).
function M.fetch_tags_async(url, on_done)
  run_async({ "git", "ls-remote", "--symref", "--", url }, function(r)
    if r.code ~= 0 then
      on_done(nil, "git ls-remote failed: " .. (r.stderr or ""))
      return
    end
    local parsed     = parse_ls_remote_symref_tags(r.stdout)
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

return M
