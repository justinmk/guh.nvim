local comments = require('guh.comments')
local config = require('guh.config')
local diff = require('guh.diff')
local pr_commands = require('guh.pr_commands')

local M = {}

M.setup = function(user_config)
  config.setup(user_config)

  vim.api.nvim_create_user_command('Guh', pr_commands.select, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhDiff', pr_commands.show_pr_diff, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhDiffview', function()
    diff.load_pr_diff('diffview')
  end, {})
  vim.api.nvim_create_user_command('GuhCheckout', pr_commands.checkout, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhApprove', pr_commands.approve_pr, {})
  vim.api.nvim_create_user_command('GuhRequestChanges', pr_commands.request_changes_pr, {})
  vim.api.nvim_create_user_command('GuhMerge', pr_commands.merge_pr, {})
  vim.api.nvim_create_user_command('GuhComment', pr_commands.comment, { bang = true, range = true })
  vim.api.nvim_create_user_command('GuhCommentEdit', comments.update_comment, { range = true })
  vim.api.nvim_create_user_command('GuhCommentDelete', comments.delete_comment, { range = true })
  vim.api.nvim_create_user_command('GuhWeb', comments.open_web_comment, { range = true })
  -- TODO: wtf is this for
  vim.api.nvim_create_user_command('GuhLoadComments', comments.load_comments, {})

  vim.api.nvim_create_autocmd('BufReadPost', {
    pattern = '*',
    callback = function(args)
      comments.load_comments_on_buffer(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd('BufEnter', {
    pattern = '*',
    callback = function(args)
      comments.load_comments_on_buffer(args.buf)
    end,
  })
end

return M
