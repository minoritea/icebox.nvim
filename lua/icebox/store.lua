local M = {}

local semver = require("icebox.semver")

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
function M.lock_path_for(url)
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

-- Returns true if the store file for `url` already exists on disk.
-- Used to distinguish "first-ever thaw call for this URL" from "cached data
-- available"; sync fetch is triggered when the file is absent.
function M.exists(url)
  return vim.fn.filereadable(M.path_for(url)) == 1
end

-- Baseline empty store — used when the file does not exist yet.
local function empty_store()
  return {
    fetched_at      = {},
    branches        = {},
    tags            = {},
    initial_pin     = {},
    initial_fetched = {},
  }
end

-- Read the store table for a URL.
--   - Missing file → empty table (a fresh store).
--   - JSON parse failure → nil + error message; callers must surface a WARN
--     and refuse to proceed rather than silently overwriting broken data.
-- The returned table is trusted as-is: no sanitize pass runs, and downstream
-- code assumes fields have their expected shapes.
function M.read(url)
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
  data.initial_pin     = data.initial_pin     or {}
  data.initial_fetched = data.initial_fetched or {}
  return data
end

-- Write the store table for a URL atomically.
function M.write(url, data)
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
--   initial_pin     (table pin_key->hash, overwrite per key)
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

  if type(new_data.initial_pin) == "table" then
    existing.initial_pin = existing.initial_pin or {}
    for pin_key, hash in pairs(new_data.initial_pin) do
      existing.initial_pin[pin_key] = hash
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

-- Return the initial pin hash for a pin_key, or nil when unset.
function M.get_initial_pin(data, pin_key)
  return data.initial_pin and data.initial_pin[pin_key]
end

-- Record an initial pin for a pin_key. Mutates `data` in place. Callers
-- must persist with M.write to make the change visible across processes.
function M.set_initial_pin(data, pin_key, hash)
  data.initial_pin = data.initial_pin or {}
  data.initial_pin[pin_key] = hash
end

-- Return whether a pin_key has ever had a successful sync fetch recorded.
function M.is_initial_fetched(data, pin_key)
  return (data.initial_fetched and data.initial_fetched[pin_key]) == true
end

-- Mark a pin_key as having completed its initial sync fetch. Mutates `data`
-- in place. Callers must persist with M.write.
function M.mark_initial_fetched(data, pin_key)
  data.initial_fetched = data.initial_fetched or {}
  data.initial_fetched[pin_key] = true
end

-- Try to acquire a lock for a URL. Returns true if acquired.
-- Writes current PID to the lock file.
function M.lock(url)
  local lock_path = M.lock_path_for(url)
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
function M.unlock(url)
  local lock_path = M.lock_path_for(url)
  os.remove(lock_path)
end

return M
