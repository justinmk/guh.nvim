local M = {}

-- Default config.
-- Keymaps are defined as `<Plug>(Guh…)` in `pr_commands.lua`.
M.s = {
  debug = false,
}

-- function M.setup(config)
--   M.s = vim.tbl_deep_extend('force', {}, M.s, config)
-- end

return M
