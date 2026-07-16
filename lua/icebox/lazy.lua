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
  if spec.icebox_options then
    -- Prefer the shorthand ("user/repo") or explicit url; fall back to a
    -- file:// URL for local dirs so the store still gets a stable key.
    -- GitHub shorthand expansion is handled inside icebox.thaw().
    -- lazy.nvim guarantees that at least one of spec[1] / spec.url / spec.dir
    -- is present, so no explicit nil guard is needed here.
    local spec_name = spec[1] or spec.url
    if not spec_name and spec.dir then
      spec_name = "file://" .. spec.dir
    end
    spec.commit = icebox.thaw(spec_name, spec.icebox_options)
  end
  return spec
end

return M
