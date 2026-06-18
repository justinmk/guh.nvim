vim.api.nvim_set_hl(0, 'GuhDiffFile', { default = true, link = 'PmenuSel' })
vim.api.nvim_set_hl(0, 'GuhHeading', { default = true, link = 'PmenuSel' })
vim.api.nvim_set_hl(0, 'GuhWarning', { default = true, link = 'WarningMsg' })

local group = vim.api.nvim_create_augroup('guh', { clear = true })

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
  pattern = 'guh://*/{prdiff,prcomments}/*',
  group = group,
  command = 'if &l:scrollbind | keepjumps syncbind | endif',
})

-- XXX: Trim leading/trailing whitespace from text copied from pr/ and issue/ buffers.
-- Workaround for:
-- - "gh" annoyingly indents pr/issue comments
-- - :terminal (currently, probably?) overuses whitespace where it should have negative space.
vim.api.nvim_create_autocmd('TextYankPost', {
  pattern = 'guh://*/{pr,issue}/*',
  group = group,
  callback = function()
    local feat = (vim.b.guh or {}).feat
    if feat ~= 'pr' and feat ~= 'prdiff' and feat ~= 'issue' then
      return
    end
    local ev = vim.v.event
    if ev.operator ~= 'y' then
      return
    end
    local stripped = {}
    for _, line in ipairs(ev.regcontents) do
      -- gh pr/issue body view prefixes comments 2 spaces; strip exactly that.
      table.insert(stripped, (line:gsub('^  ', ''):gsub('%s+$', '')))
    end
    vim.fn.setreg(ev.regname, stripped, ev.regtype)
  end,
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
vim.keymap.set('n', '<Plug>(guh-ci)', function()
  require('guh.pr').ci_rerun()
end, opts)
vim.keymap.set('n', '<Plug>(guh-edit)', function()
  require('guh.pr').edit_pr()
end, opts)
vim.keymap.set('n', '<Plug>(guh-comment)', '<cmd>GuhComment<cr>', opts)
-- Use ":" in Visual mode so the `'<,'>` range is passed to the command.
vim.keymap.set('x', '<Plug>(guh-comment)', ':GuhComment<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-comment-top)', '<cmd>%GuhComment<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-thread)', function()
  require('guh.comments').reply_or_resolve(vim.fn.line('.'))
end, opts)
vim.keymap.set('n', '<Plug>(guh-viewed)', function()
  require('guh.pr').toggle_viewed()
end, opts)
vim.keymap.set('n', '<Plug>(guh-diff)', function()
  require('guh.pr').show_pr_diff()
end, opts)
vim.keymap.set('n', '<Plug>(guh-logs)', function()
  require('guh.pr').ci_logs_pick()
end, opts)
vim.keymap.set('n', '<Plug>(guh-help)', '<cmd>help guh-mappings<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-refresh)', function()
  require('guh.pr').refresh()
end, opts)
vim.keymap.set('n', '<Plug>(guh-open)', '<cmd>Guh .<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-open-split)', '<cmd>horizontal Guh .<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-next)', function()
  require('guh.pr').show_next(1)
end, opts)
vim.keymap.set('n', '<Plug>(guh-prev)', function()
  require('guh.pr').show_next(-1)
end, opts)
