local M = {}

local semver = require("icebox.semver")

-- Default lock-acquisition timings for M.open. Kept as internal constants
-- (not user-facing) so we can revisit them without breaking any API.
local LOCK_WAIT_MS  = 5000  -- give up if the lock stays held this long
local LOCK_RETRY_MS = 50    -- poll interval while waiting for the lock

-- True on Windows (XDG env vars are rarely set there; use stdpath instead).
local function is_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

-- Returns the directory where store files live.
local function store_dir()
  local xdg = vim.env.XDG_DATA_HOME
  if not xdg or xdg == "" then
    if is_windows() then
      xdg = vim.fn.stdpath("data")
    else
      xdg = vim.fn.expand("~/.local/share")
    end
  end
  return vim.fs.joinpath(xdg, "icebox.nvim")
end

-- Returns path to the JSON file for a given URL.
function M.path_for(url)
  local sha = vim.fn.sha256(url)
  return vim.fs.joinpath(store_dir(), sha .. ".json")
end

-- Returns path to the lock file for a given URL.
local function lock_path_for(url)
  return vim.fs.joinpath(store_dir(), "locks", vim.fn.sha256(url) .. ".lock")
end

-- Returns the directory where persistent bare-clone caches live.
local function cache_root()
  local xdg = vim.env.XDG_CACHE_HOME
  if not xdg or xdg == "" then
    if is_windows() then
      xdg = vim.fn.stdpath("cache")
    else
      xdg = vim.fn.expand("~/.cache")
    end
  end
  return vim.fs.joinpath(xdg, "icebox.nvim", "clones")
end

-- Returns the cache directory for a given URL.
function M.cache_dir_for(url)
  return vim.fs.joinpath(cache_root(), vim.fn.sha256(url))
end

-- Ensure a directory exists (synchronous).
local function mkdir_p(dir)
  vim.fn.mkdir(dir, "p")
end

-- Baseline empty store; used when the file does not exist yet.
local function empty_store()
  return {
    fetched_at      = {},
    branches        = {},
    tags            = {},
    auto_pin        = {},
    initial_fetched = {},
  }
end

-- ─── File I/O helpers (private) ─────────────────────────────────────────────

-- Read the JSON store from disk. Returns (data, err):
--   - Missing file → (empty_store(), nil)
--   - JSON parse failure → (nil, err)
local function read_file(url)
  local path = M.path_for(url)
  local f = io.open(path, "r")
  if not f then
    return empty_store()
  end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok then
    return nil, "store JSON decode failed: " .. tostring(data)
  end
  if type(data) ~= "table" then
    return nil, "store JSON root is not a table"
  end
  -- Ensure the sub-tables exist so callers can index them without guards.
  data.fetched_at      = data.fetched_at      or {}
  data.branches        = data.branches        or {}
  data.tags            = data.tags            or {}
  data.auto_pin        = data.auto_pin        or {}
  data.initial_fetched = data.initial_fetched or {}
  return data
end

-- Write the store table for a URL atomically.
local function write_file(url, data)
  local path  = M.path_for(url)
  local dir   = vim.fn.fnamemodify(path, ":h")
  -- Guard against path traversal
  local real_dir = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
  local expected = vim.fn.fnamemodify(store_dir(), ":p"):gsub("/$", "")
  if real_dir ~= expected then
    return false, "store path outside expected directory"
  end
  mkdir_p(dir)

  local encoded = vim.json.encode(data)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then
    return false, "cannot open tmp file: " .. (err or "")
  end
  f:write(encoded)
  f:close()

  -- Set permissions on tmp before rename
  vim.uv.fs_chmod(tmp, tonumber("600", 8))

  local ok, rename_err = vim.uv.fs_rename(tmp, path)
  if not ok then
    return false, "rename failed: " .. (rename_err or "")
  end

  -- Ensure permissions on final file (new file may have inherited umask)
  vim.uv.fs_chmod(path, tonumber("600", 8))
  return true
end

-- ─── Lock helpers (private) ─────────────────────────────────────────────────

-- Non-blocking lock acquisition. Returns true if acquired.
-- Writes current PID to the lock file for stale-lock detection.
local function try_lock(url)
  local lock_path = lock_path_for(url)
  mkdir_p(vim.fn.fnamemodify(lock_path, ":h"))

  -- Attempt atomic create (O_CREAT|O_EXCL equivalent via "wx" flag).
  local fd = vim.uv.fs_open(lock_path, "wx", tonumber("600", 8))
  if not fd then
    -- File already exists: check whether the owning process is still alive.
    local rf = io.open(lock_path, "r")
    if not rf then return false end
    local pid = tonumber(rf:read("*a")); rf:close()
    if pid then
      -- vim.uv.kill with signal 0 tests liveness without sending a signal.
      if vim.uv.kill(pid, 0) == 0 then
        return false  -- live process holds the lock
      end
    end
    -- Stale lock: remove and retry once.
    os.remove(lock_path)
    fd = vim.uv.fs_open(lock_path, "wx", tonumber("600", 8))
    if not fd then return false end
  end

  vim.uv.fs_write(fd, tostring(vim.uv.os_getpid()))
  vim.uv.fs_close(fd)
  return true
end

-- Release the lock for a URL.
local function unlock(url)
  os.remove(lock_path_for(url))
end

-- ─── Handle API (public) ────────────────────────────────────────────────────
--
-- Store access flows through short-lived handles: open() acquires the
-- cross-process lock and loads state into memory, close() persists the
-- state and releases the lock. In between, callers mutate handle.data via
-- the in-memory helpers below (has_semver_tags, merge, get_auto_pin,
-- set_auto_pin, is_initial_fetched, mark_initial_fetched) without touching
-- disk.
--
-- Every thaw() and background-fetch call owns exactly one handle for its
-- lifetime. This keeps the "load once, mutate in memory, write once"
-- lifecycle predictable and closes the lock-window race that previously
-- lived inside git.fetch_*.

-- Open a store handle for a URL.
--   opts.timeout_ms : max ms to wait for the lock (default LOCK_WAIT_MS)
--   opts.retry_ms   : poll interval while waiting  (default LOCK_RETRY_MS)
-- Returns (handle, nil) on success, or (nil, err) on failure.
--
-- The lock is held for the lifetime of the handle. The caller MUST call
-- close() when done; the store write and unlock happen there.
function M.open(url, opts)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or LOCK_WAIT_MS
  local retry_ms   = opts.retry_ms   or LOCK_RETRY_MS

  -- vim.wait re-tests the predicate until it returns true or the timeout
  -- fires. Runs the event loop so other coroutines / callbacks still get
  -- to make progress while we spin.
  local acquired = try_lock(url)
  if not acquired then
    acquired = vim.wait(timeout_ms, function()
      return try_lock(url)
    end, retry_ms)
  end
  if not acquired then
    return nil, "store lock timeout for " .. url
  end

  local data, read_err = read_file(url)
  if not data then
    unlock(url)
    return nil, read_err or "store read failed"
  end

  return {
    url  = url,
    data = data,
  }
end

-- Persist the handle's in-memory state and release its lock. Always calls
-- unlock() so a caller that hits a write error still releases the lock.
-- Returns (true, nil) on success, or (nil, err) if the write fails.
function M.close(handle)
  local ok, write_err = write_file(handle.url, handle.data)
  unlock(handle.url)
  if not ok then
    return nil, write_err or "store write failed"
  end
  return true
end

-- ─── In-memory helpers ──────────────────────────────────────────────────────
--
-- These read/mutate the plain data table (typically handle.data). They do
-- no I/O. The change becomes visible to other processes only after
-- close() flushes the file.

-- Returns true if store.tags has at least one semver tag.
function M.has_semver_tags(data)
  for tag, _ in pairs(data.tags) do
    if semver.is_semver_tag(tag) then
      return true
    end
  end
  return false
end

-- Merge new data into existing store data. Mutates and returns `existing`.
-- new_data fields:
--   default_branch  (string, optional)
--   fetched_at      (table hash->ts, additive, no overwrite)
--   branches        (table name->hashes, full overwrite per branch)
--   tags            (table name->hash, overwrite on change)
--   auto_pin        (table pin_key->hash, overwrite per key)
--   initial_fetched (table pin_key->true, overwrite per key)
function M.merge(existing, new_data)
  if new_data.default_branch ~= nil then
    existing.default_branch = new_data.default_branch
  end

  if type(new_data.fetched_at) == "table" then
    for hash, ts in pairs(new_data.fetched_at) do
      if existing.fetched_at[hash] == nil then
        existing.fetched_at[hash] = ts
      end
    end
  end

  if type(new_data.branches) == "table" then
    for branch, hashes in pairs(new_data.branches) do
      existing.branches[branch] = hashes
    end
  end

  if type(new_data.tags) == "table" then
    for tag, hash in pairs(new_data.tags) do
      existing.tags[tag] = hash
    end
  end

  if type(new_data.auto_pin) == "table" then
    existing.auto_pin = existing.auto_pin or {}
    for pin_key, hash in pairs(new_data.auto_pin) do
      existing.auto_pin[pin_key] = hash
    end
  end

  if type(new_data.initial_fetched) == "table" then
    existing.initial_fetched = existing.initial_fetched or {}
    for pin_key, flag in pairs(new_data.initial_fetched) do
      existing.initial_fetched[pin_key] = flag
    end
  end

  return existing
end

-- Return the auto pin hash for a pin_key, or nil when unset.
function M.get_auto_pin(data, pin_key)
  return data.auto_pin and data.auto_pin[pin_key]
end

-- Record an auto pin for a pin_key. Mutates `data` in place.
function M.set_auto_pin(data, pin_key, hash)
  data.auto_pin = data.auto_pin or {}
  data.auto_pin[pin_key] = hash
end

-- Return whether a pin_key has ever had a successful sync fetch recorded.
function M.is_initial_fetched(data, pin_key)
  return (data.initial_fetched and data.initial_fetched[pin_key]) == true
end

-- Mark a pin_key as having completed its initial sync fetch. Mutates `data`
-- in place.
function M.mark_initial_fetched(data, pin_key)
  data.initial_fetched = data.initial_fetched or {}
  data.initial_fetched[pin_key] = true
end

return M
