vim.api.nvim_set_hl(0, 'GuhDiffFile', { default = true, link = 'PmenuSel' })
vim.api.nvim_set_hl(0, 'GuhHeading', { default = true, link = 'PmenuSel' })
vim.api.nvim_set_hl(0, 'GuhWarning', { default = true, link = 'WarningMsg' })

local group = vim.api.nvim_create_augroup('guh', { clear = true })

-- ":edit guh://pr/owner/repo/N" (etc.) dispatches to :Guh.
vim.api.nvim_create_autocmd('BufReadCmd', {
  pattern = 'guh://*',
  group = group,
  callback = function(args)
    -- Treat no-args ":edit" as "reload"
    if (vim.b[args.buf].guh or {}).feat then
      vim.schedule(require('guh.pr').refresh)
      return
    end
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(args.buf) then
        vim.api.nvim_buf_delete(args.buf, { force = true }) -- Wipe the placeholder :edit created.
      end
      vim.cmd('Guh ' .. vim.fn.fnameescape(args.match))
    end)
  end,
})

-- Define a fixed 'winbar' for each "feat". `%{b:guh.…}` segments read `b:guh` fields directly. `%{…}` is Vimscript = no marshalling.
--
-- - Dynamic groups (state/title color) use the `%{%…%}` form (note: an empty group `%##` is harmless).
-- - Separators: only `title` is preceded by a "|".
local status = [[%{%'%#' .. b:guh.status_hl .. '#' .. b:guh.status .. '%*'%}]]
local winbar = {
  issue = [[ISSUE #%{b:guh.id}%( %#WarningMsg#%{b:guh.unread}%*%)]],
  pr = [[PR #%{b:guh.id} ]]
    .. status
    .. [[%( %#WarningMsg#%{b:guh.unread}%*%)%( %#WarningMsg#Target: %{b:guh.branch}%*%) | %{b:guh.title}%<]],
  prcomments = [[PR COMMENTS | Unresolved: %{b:guh.n_visible_threads} | Unresolved in %#@markup.italic#Viewed%*: %{b:guh.n_viewed_threads}%<]],
  prdiff = [[PR DIFF | Files: %{b:guh.n_files} (%#@markup.italic#Viewed%*: %{b:guh.n_viewed}) | Unresolved: %{b:guh.n_visible_threads}%<]],
  prlogs = [[LOGS | PR #%{b:guh.id} | ]] .. status .. [[ %{b:guh.title}%<]],
  repo = [[REPO %{b:guh.repo}]],
  status = [[STATUS]],
}
-- Edit feats: the (optionally colored) `title` prompt + per-feat help hint.
local title = [[%{%'%#' .. b:guh.title_hl .. '#' .. b:guh.title .. '%*'%}%<]]
winbar.comment = title .. [[ | ZZ to save (ZQ to abort)]]
winbar.merge = title .. [[ | First line = subject; rest = body | ZZ to merge (ZQ to abort)]]
winbar.review = title .. [[ | ZZ to submit (ZQ to abort)]]

-- Every guh:// window gets a 'winbar'.
vim.api.nvim_create_autocmd('BufWinEnter', {
  pattern = 'guh://*',
  group = group,
  callback = function()
    vim.wo.winbar = winbar[(vim.b.guh or {}).feat] or ''
  end,
})

-- :syncbind the prdiff/prcomments windows.
vim.api.nvim_create_autocmd({ 'WinEnter', 'WinResized' }, {
  pattern = [[guh://[^/]\+/[^/]\+/{prdiff,prcomments}/*]],
  group = group,
  command = 'if &l:scrollbind | keepjumps syncbind | endif',
})

-- XXX: Trim leading/trailing whitespace from text copied from pr/ and issue/ buffers.
-- Workaround for:
-- - "gh" annoyingly indents pr/issue comments
-- - :terminal (currently, probably?) overuses whitespace where it should have negative space.
vim.api.nvim_create_autocmd('TextYankPost', {
  pattern = [[guh://[^/]\+/[^/]\+/issue/*]],
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

-- Buffer-relative VIEW actions:
vim.keymap.set('n', '<Plug>(guh-help)', '<cmd>help guh-mappings<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-up)', function()
  require('guh.pr').go_up()
end, opts)
vim.keymap.set('n', '<Plug>(guh-refresh)', function()
  require('guh.pr').refresh()
end, opts)
vim.keymap.set('n', '<Plug>(guh-web)', function()
  local url = require('guh.gh').get_url(0)
  if url then
    vim.ui.open(url)
  else
    require('guh.util').msg('No URL for this buffer', vim.log.levels.WARN)
  end
end, opts)
vim.keymap.set('n', '<Plug>(guh-diff)', function()
  require('guh.pr').show_pr_diff()
end, opts)
vim.keymap.set('n', '<Plug>(guh-logs)', function()
  require('guh.pr').ci_logs_pick()
end, opts)
vim.keymap.set('n', '<Plug>(guh-next)', function()
  require('guh.pr').show_next(1)
end, opts)
vim.keymap.set('n', '<Plug>(guh-prev)', function()
  require('guh.pr').show_next(-1)
end, opts)

-- Buffer-relative UPDATE actions:
vim.keymap.set('n', '<Plug>(guh-ci)', function()
  require('guh.pr').ci_rerun()
end, opts)
vim.keymap.set('n', '<Plug>(guh-comment-top)', '<cmd>%GuhComment<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-edit)', function()
  require('guh.pr').edit_pr()
end, opts)
vim.keymap.set('n', '<Plug>(guh-merge)', function()
  require('guh.pr').merge_pr()
end, opts)
vim.keymap.set('n', '<Plug>(guh-notif-read)', function()
  require('guh.pr').set_read()
end, opts)
vim.keymap.set('n', '<Plug>(guh-review)', function()
  require('guh.pr').review_pr()
end, opts)

-- Cursor-relative actions:
vim.keymap.set('n', '<Plug>(guh-open)', '<cmd>Guh .<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-open-split)', '<cmd>horizontal Guh .<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-comment)', '<cmd>GuhComment<cr>', opts)
-- Use ":" so the Visual range '<,'> is passed to the command.
vim.keymap.set('x', '<Plug>(guh-comment)', ':GuhComment<cr>', opts)
vim.keymap.set('n', '<Plug>(guh-file)', function()
  require('guh.pr').show_file()
end, opts)
vim.keymap.set('n', '<Plug>(guh-thread)', function()
  require('guh.comments').reply_or_resolve(vim.fn.line('.'))
end, opts)
vim.keymap.set('n', '<Plug>(guh-viewed)', function()
  require('guh.pr').toggle_viewed()
end, opts)
