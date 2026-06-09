vim.api.nvim_set_hl(0, 'GuhHeading', { default = true, link = 'PmenuSel' })
vim.api.nvim_set_hl(0, 'GuhWarning', { default = true, link = 'WarningMsg' })

local group = vim.api.nvim_create_augroup('guh.keymaps', { clear = true })

-- ":edit guh://pr/owner/repo/N" (etc.) dispatches to :Guh.
-- Wipe the placeholder buffer that :edit created.
vim.api.nvim_create_autocmd('BufReadCmd', {
  pattern = 'guh://*',
  group = group,
  callback = function(args)
    local uri = args.match
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(args.buf) then
        vim.api.nvim_buf_delete(args.buf, { force = true })
      end
      vim.cmd('Guh ' .. vim.fn.fnameescape(uri))
    end)
  end,
})

-- :syncbind the prdiff/prcomments windows.
vim.api.nvim_create_autocmd({ 'WinEnter', 'WinResized' }, {
  pattern = { 'guh://*/prdiff/*', 'guh://*/prcomments/*' },
  group = group,
  command = 'keepjumps syncbind',
})

vim.api.nvim_create_user_command('Guh', function(args)
  require('guh.pr').select(args)
end, { nargs = '?' })
vim.api.nvim_create_user_command('GuhComment', function(args)
  require('guh.pr').comment(args)
end, { bang = true, range = true })

local opts = { silent = true }
vim.keymap.set('n', '<Plug>(guh-review)', function()
  require('guh.pr').review_pr()
end, opts)
vim.keymap.set('n', '<Plug>(guh-merge)', function()
  require('guh.pr').merge_pr()
end, opts)
vim.keymap.set('n', '<Plug>(guh-edit)', function()
  require('guh.pr').edit_pr()
end, opts)
vim.keymap.set('n', '<Plug>(guh-comment)', '<cmd>GuhComment<cr>', opts)
-- Use ":" in Visual mode so the `'<,'>` range is passed to the command.
vim.keymap.set('x', '<Plug>(guh-comment)', ':GuhComment<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-comment-overview)', '<cmd>%GuhComment<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-thread)', function()
  require('guh.comments').reply_or_resolve(vim.fn.line('.'))
end, opts)
vim.keymap.set('n', '<Plug>(guh-diff)', function()
  require('guh.pr').show_pr_diff()
end, opts)
vim.keymap.set('n', '<Plug>(guh-logs)', function()
  require('guh.pr').show_ci_logs()
end, opts)
vim.keymap.set('n', '<Plug>(guh-help)', '<cmd>help guh-mappings<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-refresh)', function()
  require('guh.pr').refresh()
end, opts)
vim.keymap.set('n', '<Plug>(guh-open)', function()
  vim.cmd.Guh(vim.fn.expand('<cWORD>'))
end, opts)
vim.keymap.set('n', '<Plug>(guh-open-split)', function()
  vim.api.nvim_cmd({ cmd = 'Guh', args = { vim.fn.expand('<cWORD>') }, mods = { horizontal = true } }, {})
end, opts)
vim.keymap.set('n', '<Plug>(guh-next)', function()
  require('guh.pr').show_next(1)
end, opts)
vim.keymap.set('n', '<Plug>(guh-prev)', function()
  require('guh.pr').show_next(-1)
end, opts)
