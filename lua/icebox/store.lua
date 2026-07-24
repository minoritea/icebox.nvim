local M = {}

local validate = require("icebox.validate")
local semver   = require("icebox.semver")

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

-- Validate a single store table loaded from JSON. Strips invalid entries in-place.
local function sanitize(data)
  if type(data) ~= "table" then return {} end

  -- default_branch
  if data.default_branch ~= nil then
    local ok = validate.branch(data.default_branch)
    if not ok then data.default_branch = nil end
  end

  -- fetched_at
  if type(data.fetched_at) ~= "table" then
    data.fetched_at = {}
  else
    local clean = {}
    for hash, ts in pairs(data.fetched_at) do
      local ok_h = validate.commit_hash(hash)
      if ok_h and type(ts) == "number" and ts > 0 and math.floor(ts) == ts then
        clean[hash] = ts
      end
    end
    data.fetched_at = clean
  end

  -- branches
  if type(data.branches) ~= "table" then
    data.branches = {}
  else
    local clean = {}
    for branch, hashes in pairs(data.branches) do
      local ok_b = validate.branch(branch)
      if ok_b and type(hashes) == "table" then
        local clean_hashes = {}
        for _, h in ipairs(hashes) do
          if validate.commit_hash(h) then
            clean_hashes[#clean_hashes + 1] = h
          end
        end
        clean[branch] = clean_hashes
      end
    end
    data.branches = clean
  end

  -- tags
  if type(data.tags) ~= "table" then
    data.tags = {}
  else
    local clean = {}
    for tag, hash in pairs(data.tags) do
      if validate.tag(tag) and validate.commit_hash(hash) then
        clean[tag] = hash
      end
    end
    data.tags = clean
  end

  return data
end

-- Read and return the store table for a URL. Returns a fresh empty table if not found.
function M.read(url)
  local path = M.path_for(url)
  local f = io.open(path, "r")
  if not f then
    return { fetched_at = {}, branches = {}, tags = {} }
  end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return { fetched_at = {}, branches = {}, tags = {} }
  end
  return sanitize(data)
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

-- Returns true if fetched_at has at least one entry.
function M.has_records(data)
  return next(data.fetched_at) ~= nil
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

  return existing
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
