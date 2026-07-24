local M = {}

-- Built-in defaults. Applied every time setup() runs so calls are idempotent:
-- the resulting state is always DEFAULTS overlaid with the arguments of the
-- most recent call. Keys not present in {opts} revert to their default value.
local DEFAULTS = {
  cooldown_days            = 7,
  trust_on_first_use       = false,
  branch_commits_per_fetch = 500,
}

local _cfg = vim.deepcopy(DEFAULTS)

-- Replace the process-wide config with DEFAULTS plus the provided opts.
-- Idempotent: setup({X=1}); setup({Y=2}) resets X back to its default.
function M.set(opts)
  local new_cfg = vim.deepcopy(DEFAULTS)
  if type(opts) == "table" then
    if type(opts.cooldown_days) == "number" and opts.cooldown_days >= 0
      and math.floor(opts.cooldown_days) == opts.cooldown_days then
      new_cfg.cooldown_days = opts.cooldown_days
    end
    if type(opts.trust_on_first_use) == "boolean" then
      new_cfg.trust_on_first_use = opts.trust_on_first_use
    end
    if type(opts.branch_commits_per_fetch) == "number"
      and opts.branch_commits_per_fetch >= 1
      and math.floor(opts.branch_commits_per_fetch) == opts.branch_commits_per_fetch then
      new_cfg.branch_commits_per_fetch = opts.branch_commits_per_fetch
    end
  end
  _cfg = new_cfg
end

function M.get()
  return vim.deepcopy(_cfg)
end

-- Return a cfg table with per-thaw overrides applied on top of the current
-- setup values. Only the three tunable keys are considered; nil values in
-- `overrides` fall through to the setup value. The stored `_cfg` is not
-- mutated so the override is scoped to a single thaw() call.
function M.merge_overrides(overrides)
  local cfg = vim.deepcopy(_cfg)
  if type(overrides) ~= "table" then return cfg end
  if overrides.cooldown_days ~= nil then
    cfg.cooldown_days = overrides.cooldown_days
  end
  if overrides.trust_on_first_use ~= nil then
    cfg.trust_on_first_use = overrides.trust_on_first_use
  end
  if overrides.branch_commits_per_fetch ~= nil then
    cfg.branch_commits_per_fetch = overrides.branch_commits_per_fetch
  end
  return cfg
end

return M
