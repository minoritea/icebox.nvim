local M = {}

local _cfg = {
  cooldown_days      = 7,
  trust_on_first_use = false,
}

function M.set(opts)
  if type(opts) ~= "table" then return end
  if type(opts.cooldown_days) == "number" and opts.cooldown_days >= 0 then
    _cfg.cooldown_days = opts.cooldown_days
  end
  if type(opts.trust_on_first_use) == "boolean" then
    _cfg.trust_on_first_use = opts.trust_on_first_use
  end
end

function M.get()
  return vim.deepcopy(_cfg)
end

return M
