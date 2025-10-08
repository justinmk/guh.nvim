local config = require('guh.config')
local pr_commands = require('guh.pr_commands')

local M = {}

M.setup = function(user_config)
  config.setup(user_config)

  vim.api.nvim_create_user_command('Guh', pr_commands.select, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhDiff', pr_commands.show_pr_diff, { nargs = '?' })
  -- vim.api.nvim_create_user_command('GuhCheckout', pr_commands.checkout, { nargs = '?' })
  -- vim.api.nvim_create_user_command('GuhApprove', pr_commands.approve_pr, {})
  -- vim.api.nvim_create_user_command('GuhRequestChanges', pr_commands.request_changes_pr, {})
  -- vim.api.nvim_create_user_command('GuhMerge', pr_commands.merge_pr, {})
  -- vim.api.nvim_create_user_command('GuhComment', pr_commands.comment, { bang = true, range = true })
  -- vim.api.nvim_create_user_command('GuhCommentEdit', comments.update_comment, { range = true })
  -- vim.api.nvim_create_user_command('GuhCommentDelete', comments.delete_comment, { range = true })
end

return M
