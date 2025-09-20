local comments = require('ghlite.comments')
local config = require('ghlite.config')
local diff = require('ghlite.diff')
local pr_commands = require('ghlite.pr_commands')

local M = {}

M.setup = function(user_config)
  config.setup(user_config)

  vim.api.nvim_create_user_command('GHLitePRSelect', pr_commands.select, { nargs = '?' })
  vim.api.nvim_create_user_command('GHLitePRCheckout', pr_commands.checkout, { nargs = '?' })
  vim.api.nvim_create_user_command('GHLitePRView', pr_commands.load_pr_view, { nargs = '?' })
  vim.api.nvim_create_user_command('GHLitePRApprove', pr_commands.approve_pr, {})
  vim.api.nvim_create_user_command('GHLitePRRequestChanges', pr_commands.request_changes_pr, {})
  vim.api.nvim_create_user_command('GHLitePRMerge', pr_commands.merge_pr, {})
  vim.api.nvim_create_user_command('GHLitePRAddPRComment', pr_commands.comment_on_pr, {})
  vim.api.nvim_create_user_command('GHLitePRLoadComments', comments.load_comments, {})
  vim.api.nvim_create_user_command('GHLitePRDiff', diff.load_pr_diff, {})
  vim.api.nvim_create_user_command('GHLitePRDiffview', diff.load_pr_diffview, {})
  vim.api.nvim_create_user_command('GHLitePRAddComment', comments.comment_on_line, { range = true })
  vim.api.nvim_create_user_command('GHLitePRUpdateComment', comments.update_comment, {})
  vim.api.nvim_create_user_command('GHLitePROpenComment', comments.open_comment, {})
  vim.api.nvim_create_user_command('GHLitePRDeleteComment', comments.delete_comment, {})

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
