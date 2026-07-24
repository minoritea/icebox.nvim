local M = {}

local validate = require("icebox.validate")

local CLONE_SAFETY_ARGS = {
  "--no-local",
  "--no-hardlinks",
  "-c", "core.hooksPath=/dev/null",
  "-c", "core.fsmonitor=false",
  "--filter=blob:none",
}

-- ─── Parsers ────────────────────────────────────────────────────────────────

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

-- Parse the stdout of `git symbolic-ref <ref>` into a plain branch name.
-- Handles both `refs/heads/<name>` (from a bare/fresh HEAD) and
-- `refs/remotes/<remote>/<name>` (from `refs/remotes/origin/HEAD`).
local function parse_symref_stdout(stdout)
  return stdout:match("refs/heads/(.-)%s*$")
    or stdout:match("refs/heads/(.+)$")
    or stdout:match("refs/remotes/[^/]+/(.-)%s*$")
    or stdout:match("refs/remotes/[^/]+/(.+)$")
end

-- ─── run_cmd: sync/async dispatcher ─────────────────────────────────────────
--
-- The single command-execution primitive used throughout this module. When
-- called inside a coroutine (async context) it schedules vim.system and
-- yields, resuming with the result when the process exits. When called
-- outside a coroutine (sync context) it blocks on :wait().
--
-- Every git-related helper below is written *once* against this primitive;
-- the public sync/async entry points differ only in whether they run their
-- pipeline inside a coroutine wrapper or not.

local function run_cmd(cmd)
  local co = coroutine.running()
  if co then
    vim.system(cmd, { text = true }, function(r)
      vim.schedule(function() coroutine.resume(co, r) end)
    end)
    return coroutine.yield()
  end
  return vim.system(cmd, { text = true }):wait()
end

-- ─── Small helpers ──────────────────────────────────────────────────────────

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
local function is_healthy_repo(dir)
  if vim.fn.isdirectory(dir) ~= 1 then return false end
  local r = run_cmd({
    "git", "-C", dir,
    "-c", "safe.directory=*",
    "rev-parse", "--git-dir",
  })
  if r.code ~= 0 then return false end
  local out = (r.stdout or ""):gsub("%s+$", "")
  return out == "." or out == dir
end

-- Resolve a symbolic-ref to a branch name. `ref` defaults to "HEAD" (bare /
-- freshly-cloned repos). For non-bare user clones (as with clone_path) pass
-- "refs/remotes/origin/HEAD" so we track the origin's default branch rather
-- than whatever the user has checked out locally.
local function read_default_branch(dir, ref)
  local r = run_cmd({ "git", "-C", dir, "symbolic-ref", ref or "HEAD" })
  if r.code ~= 0 then return nil end
  return parse_symref_stdout(r.stdout)
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

-- ─── Public: origin_url ─────────────────────────────────────────────────────

-- Read the `origin` remote URL from a local repo. Returns url string or nil + err.
function M.origin_url(clone_path)
  local r = run_cmd({ "git", "-C", clone_path, "remote", "get-url", "origin" })
  if r.code ~= 0 then
    return nil, "origin not set in clone_path: " .. (r.stderr or ""):gsub("%s+$", "")
  end
  local url = (r.stdout or ""):gsub("%s+$", "")
  if url == "" then
    return nil, "origin URL is empty"
  end
  return url
end

-- ─── Pipeline implementations (single source of truth) ──────────────────────

-- Fetch a branch history from `clone_path`, which is an EXISTING local clone
-- maintained by another tool (e.g. a plugin manager) — NOT an icebox cache.
-- Preconditions: the path exists and is a git repository (validate.clone_path
-- enforces this at the call site). This function never creates, initializes,
-- or clones into the path; a missing/broken directory is treated as an error.
-- The clone is used non-destructively: only FETCH_HEAD is updated, no local
-- refs or working tree state is touched.
local function fetch_branch_from_clone(url, branch, limit, clone_path)
  local health = run_cmd({ "git", "-C", clone_path, "rev-parse", "--git-dir" })
  if health.code ~= 0 then
    return nil, "clone_path is not a git repository: " .. clone_path
  end
  local fetch_cmd = { "git", "-C", clone_path, "fetch", "--no-tags", "--", url }
  if branch then fetch_cmd[#fetch_cmd + 1] = branch end
  local fr = run_cmd(fetch_cmd)
  if fr.code ~= 0 then
    return nil, "git fetch failed: " .. (fr.stderr or "")
  end
  local log_r = run_cmd(build_log_cmd(clone_path, limit, "FETCH_HEAD"))
  if log_r.code ~= 0 then
    return nil, "git log failed: " .. (log_r.stderr or "")
  end
  local hashes = parse_log(log_r.stdout)
  -- Seed default_branch from the origin's tracked HEAD (best-effort).
  local default_branch = read_default_branch(clone_path, "refs/remotes/origin/HEAD")
  return build_branch_data(hashes, branch or default_branch or "HEAD", default_branch)
end

-- Ensure the bare repo at `cache_dir` is present and up-to-date for `branch`.
-- Returns the ref name to read history from, or nil + err.
--   - Fresh clone → "HEAD"
--   - Existing cache after fetch → "FETCH_HEAD"
-- If an existing cache passes the health check but the fetch itself fails
-- (e.g. origin URL changed, cache subtly corrupted between checks), the cache
-- is wiped and a fresh clone is attempted.
local function ensure_cache(cache_dir, url, branch)
  if is_healthy_repo(cache_dir) then
    local ref = branch and ("refs/heads/" .. branch) or "HEAD"
    local fr = run_cmd({ "git", "-C", cache_dir, "fetch", "origin", ref })
    if fr.code == 0 then
      return "FETCH_HEAD"
    end
    -- Fall through to re-clone.
  end
  rmdir_rf(cache_dir)
  vim.fn.mkdir(vim.fn.fnamemodify(cache_dir, ":h"), "p")
  local cr = run_cmd(build_clone_cmd(url, branch, cache_dir))
  if cr.code ~= 0 then
    return nil, "git clone failed: " .. (cr.stderr or "")
  end
  return "HEAD"
end

-- Fetch a branch using icebox's own bare-clone cache directory.
local function fetch_branch_from_cache(url, branch, limit, cache_dir)
  local ref, err = ensure_cache(cache_dir, url, branch)
  if not ref then return nil, err end
  local default_branch = read_default_branch(cache_dir)
  local log_r = run_cmd(build_log_cmd(cache_dir, limit, ref))
  if log_r.code ~= 0 then
    return nil, "git log failed: " .. (log_r.stderr or "")
  end
  local hashes = parse_log(log_r.stdout)
  return build_branch_data(hashes, branch or default_branch or "HEAD", default_branch)
end

-- Single-source branch fetch pipeline. `opts` must supply exactly one of
-- `opts.cache_dir` (icebox-owned persistent bare clone) or `opts.clone_path`
-- (EXISTING externally-managed clone; read-only via FETCH_HEAD).
local function fetch_branch_impl(url, branch, limit, opts)
  if opts.clone_path then
    return fetch_branch_from_clone(url, branch, limit, opts.clone_path)
  end
  return fetch_branch_from_cache(url, branch, limit, opts.cache_dir)
end

-- Single-source tag/version fetch pipeline. Always uses `git ls-remote`
-- (network); `clone_path` is intentionally not consulted for this path.
local function fetch_tags_impl(url)
  local r = run_cmd({ "git", "ls-remote", "--symref", "--", url })
  if r.code ~= 0 then
    return nil, "git ls-remote failed: " .. (r.stderr or "")
  end
  local parsed     = parse_ls_remote_symref_tags(r.stdout)
  local now        = os.time()
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

-- ─── Sync/async wrappers ────────────────────────────────────────────────────
--
-- Sync entry points invoke the pipeline directly (no coroutine → run_cmd
-- takes the :wait() branch). Async entry points wrap the pipeline in a
-- coroutine and deliver the return values via callback.

local function run_async_pipeline(pipeline_fn, on_done)
  coroutine.wrap(function()
    on_done(pipeline_fn())
  end)()
end

function M.fetch_branch_sync(url, branch, limit, opts)
  return fetch_branch_impl(url, branch, limit, opts)
end

function M.fetch_branch_async(url, branch, limit, opts, on_done)
  run_async_pipeline(function()
    return fetch_branch_impl(url, branch, limit, opts)
  end, on_done)
end

function M.fetch_tags_sync(url)
  return fetch_tags_impl(url)
end

function M.fetch_tags_async(url, on_done)
  run_async_pipeline(function()
    return fetch_tags_impl(url)
  end, on_done)
end

return M
