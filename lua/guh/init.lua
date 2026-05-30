local config = require('guh.config')

local M = {}

M.setup = function(user_config)
  config.setup(user_config)

  vim.api.nvim_create_autocmd('BufFilePost', {
    pattern = 'guh://*',
    group = vim.api.nvim_create_augroup('guh.keymaps', { clear = true }),
    callback = function(args)
      vim.keymap.set('n', '<CR>', function()
        local text = vim.fn.expand('<cWORD>')
        if require('guh.util').parse_target(text) then
          vim.cmd('Guh ' .. text)
        end
      end, { buffer = args.buf, desc = 'Open :Guh target at cursor' })
    end,
  })

  vim.api.nvim_create_user_command('Guh', require('guh.pr_commands').select, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhDiff', require('guh.pr_commands').show_pr_diff, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhComment', require('guh.pr_commands').comment, { bang = true, range = true })
  vim.api.nvim_create_user_command('GuhLoadComments', require('guh.pr_commands').load_comments, { nargs = '?' })
  -- vim.api.nvim_create_user_command('GuhCheckout', require('guh.pr_commands').checkout, { nargs = '?' })
  -- vim.api.nvim_create_user_command('GuhApprove', require('guh.pr_commands').approve_pr, {})
  -- vim.api.nvim_create_user_command('GuhRequestChanges', require('guh.pr_commands').request_changes_pr, {})
  -- vim.api.nvim_create_user_command('GuhMerge', require('guh.pr_commands').merge_pr, {})
  -- vim.api.nvim_create_user_command('GuhCommentEdit', comments.update_comment, { range = true })
  -- vim.api.nvim_create_user_command('GuhCommentDelete', comments.delete_comment, { range = true })
end

return M
