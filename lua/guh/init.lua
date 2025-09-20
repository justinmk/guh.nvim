local comments = require('guh.comments')
local config = require('guh.config')
local diff = require('guh.diff')
local pr_commands = require('guh.pr_commands')

local M = {}

M.setup = function(user_config)
  config.setup(user_config)

  vim.api.nvim_create_user_command('GuhSelect', pr_commands.select, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhCheckout', pr_commands.checkout, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhView', pr_commands.load_pr_view, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhApprove', pr_commands.approve_pr, {})
  vim.api.nvim_create_user_command('GuhRequestChanges', pr_commands.request_changes_pr, {})
  vim.api.nvim_create_user_command('GuhMerge', pr_commands.merge_pr, {})
  vim.api.nvim_create_user_command('GuhComment', pr_commands.comment_on_pr, {})
  vim.api.nvim_create_user_command('GuhLoadComments', comments.load_comments, {})
  vim.api.nvim_create_user_command('GuhDiff', diff.load_pr_diff, {})
  vim.api.nvim_create_user_command('GuhDiffview', diff.load_pr_diffview, {})
  vim.api.nvim_create_user_command('GuhComment', comments.comment_on_line, { range = true })
  vim.api.nvim_create_user_command('GuhUpdateComment', comments.update_comment, {})
  vim.api.nvim_create_user_command('GuhWebComment', comments.open_comment, {})
  vim.api.nvim_create_user_command('GuhDeleteComment', comments.delete_comment, {})

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
