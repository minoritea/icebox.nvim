local M = {}
local icebox = require("icebox")

--- Wrap a lazy.nvim plugin spec: if `spec.icebox_options` is present, resolve
--- a cooled-down commit via icebox.thaw() and assign it to `spec.commit`.
--- Specs without `icebox_options` are returned untouched.
---
--- The spec is mutated in place and also returned, so the function is usable
--- both as an in-place transform and directly with vim.tbl_map():
---
--- Usage:
---   local cooldown = require("icebox.lazy").cooldown
---   require("lazy").setup(vim.tbl_map(cooldown, {
---     { "user/repo", icebox_options = { branch = "main" } },
---     { "plain/plugin" },  -- no icebox_options → passed through unchanged
---     ...
---   }))
---
--- @param spec table lazy.nvim plugin spec
--- @return table  the same spec (mutated)
function M.cooldown(spec)
  if not spec.icebox_options then
    return spec
  end
  -- Prefer the shorthand ("user/repo") or explicit url; fall back to
  -- spec.dir (which lazy.nvim uses for local plugins). lazy.nvim guarantees
  -- at least one of spec[1] / spec.url / spec.dir is present on any valid
  -- spec, so no explicit nil guard is needed here.
  local spec_name = spec[1] or spec.url or spec.dir
  -- When spec.dir is chosen, require it to be an absolute path (Unix-style
  -- leading "/"). Relative paths cannot be resolved deterministically and
  -- would let the store key on ambiguous strings.
  if spec_name == spec.dir and spec_name:sub(1, 1) ~= "/" then
    vim.notify("[icebox] spec.dir must be an absolute path: " .. spec_name,
               vim.log.levels.WARN)
    spec.commit = icebox.ZERO_HASH
    return spec
  end
  spec.commit = icebox.thaw(spec_name, spec.icebox_options)
  return spec
end

return M
