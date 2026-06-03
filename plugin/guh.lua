require('guh').setup({})

-- `<Plug>(guh-…)` mappings. Defined here (not in lua/) so they're available
-- at plugin-load time without pulling pr_commands into startup. The actual
-- handlers are required lazily on first invocation.
local opts = { silent = true }
vim.keymap.set('n', '<Plug>(guh-approve)', function()
  require('guh.pr_commands').approve_pr()
end, opts)
vim.keymap.set('n', '<Plug>(guh-request-changes)', function()
  require('guh.pr_commands').request_changes_pr()
end, opts)
vim.keymap.set('n', '<Plug>(guh-merge)', function()
  require('guh.pr_commands').merge_pr()
end, opts)
vim.keymap.set('n', '<Plug>(guh-merge-admin)', function()
  require('guh.pr_commands').merge_pr(true)
end, opts)
vim.keymap.set({ 'n', 'x' }, '<Plug>(guh-comment)', '<cmd>GuhComment<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-diff)', function()
  require('guh.pr_commands').show_pr_diff()
end, opts)
vim.keymap.set('n', '<Plug>(guh-logs)', function()
  require('guh.pr_commands').show_ci_logs()
end, opts)
vim.keymap.set('n', '<Plug>(guh-help)', '<cmd>help guh-mappings<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-refresh)', function()
  require('guh.pr_commands').refresh()
end, opts)
