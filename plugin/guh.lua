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

vim.api.nvim_create_autocmd('BufFilePost', {
  pattern = 'guh://*',
  group = group,
  callback = function(args)
    vim.keymap.set('n', '<Enter>', function()
      local util = require('guh.util')
      local text = vim.fn.expand('<cWORD>')
      -- Flash the cWORD so the user can see what got picked.
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local line = vim.api.nvim_get_current_line()
      local s = (line:sub(1, col + 1):match('()%S+$') or col + 2) - 1
      vim.hl.range(
        0,
        vim.api.nvim_create_namespace('guh.cword_hl'),
        'Visual',
        { row - 1, s },
        { row - 1, s + #text },
        { timeout = 200 }
      )
      local done = util.progress('Loading...')
      vim.schedule(function()
        vim.cmd('Guh ' .. text)
        done()
      end)
    end, { buffer = args.buf, desc = 'Open :Guh target at cursor' })
  end,
})

vim.api.nvim_create_user_command('Guh', function(opts)
  require('guh.pr').select(opts)
end, { nargs = '?' })
vim.api.nvim_create_user_command('GuhComment', function(opts)
  require('guh.pr').comment(opts)
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
vim.keymap.set({ 'n', 'x' }, '<Plug>(guh-comment)', '<cmd>GuhComment<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-comment-overview)', '<cmd>GuhComment!<cr>', opts)
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
