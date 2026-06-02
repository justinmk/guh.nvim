local config = require('guh.config')

local M = {}

M.setup = function(user_config)
  config.setup(user_config)

  vim.api.nvim_create_autocmd('BufFilePost', {
    pattern = 'guh://*',
    group = vim.api.nvim_create_augroup('guh.keymaps', { clear = true }),
    callback = function(args)
      vim.keymap.set('n', '<CR>', function()
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

  vim.api.nvim_create_user_command('Guh', require('guh.pr_commands').select, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhDiff', require('guh.pr_commands').show_pr_diff, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhComment', require('guh.pr_commands').comment, { bang = true, range = true })
  -- vim.api.nvim_create_user_command('GuhCheckout', require('guh.pr_commands').checkout, { nargs = '?' })
  -- vim.api.nvim_create_user_command('GuhApprove', require('guh.pr_commands').approve_pr, {})
  -- vim.api.nvim_create_user_command('GuhRequestChanges', require('guh.pr_commands').request_changes_pr, {})
  -- vim.api.nvim_create_user_command('GuhMerge', require('guh.pr_commands').merge_pr, {})
  -- vim.api.nvim_create_user_command('GuhCommentEdit', comments.update_comment, { range = true })
  -- vim.api.nvim_create_user_command('GuhCommentDelete', comments.delete_comment, { range = true })
end

return M
