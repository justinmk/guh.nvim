local comments_utils = require('guh.comments_utils')
local config = require('guh.config')
local gh = require('guh.gh')
local pr_utils = require('guh.pr_utils')
local utils = require('guh.utils')

local M = {}

local severity = vim.diagnostic.severity

local function load_comments_to_quickfix_list()
  local comments_list = vim.b.guh_comments
  if not comments_list then
    return utils.notify('No comments loaded for this buffer.')
  end

  local qf_entries = {}

  local filenames = {}
  for fn in pairs(comments_list) do
    table.insert(filenames, fn)
  end
  table.sort(filenames)

  for _, filename in pairs(filenames) do
    local comments_in_file = comments_list[filename]

    table.sort(comments_in_file, function(a, b)
      return a.line < b.line
    end)

    for _, comment in pairs(comments_in_file) do
      if #comment.comments > 0 then
        table.insert(qf_entries, {
          filename = filename,
          lnum = comment.line,
          text = comment.content,
        })
      end
    end
  end

  if #qf_entries > 0 then
    vim.fn.setqflist(qf_entries, 'r')
    vim.cmd('cfirst')
  else
    utils.notify('No GH comments loaded.')
  end
end

M.load_comments = function()
  pr_utils.get_selected_pr(function(pr)
    if pr == nil then
      return utils.notify('No PR to work with.', vim.log.levels.WARN)
    end

    local progress = utils.new_progress_report('Loading comments', vim.fn.bufnr())
    gh.load_comments(pr.number, function(comments_list)
      vim.b.guh_comments = comments_list
      vim.schedule(function()
        load_comments_to_quickfix_list()

        M.load_comments_on_current_buffer()
        progress('success')
      end)
    end)
  end)
end

M.load_comments_only = function(pr_to_load, cb)
  gh.load_comments(pr_to_load, function(comments_list)
    vim.b.guh_comments = comments_list
    cb()
  end)
end

local function validate_cur_filename(f)
  if f == nil then
    utils.notify('You are on a branch without PR.', vim.log.levels.WARN)
    return false
  end

  if f:match('guh://pr/') or f:match('guh://issue/') then
    utils.notify('This command is for file comments. Use :GuhComment for PR/issue comments.', vim.log.levels.WARN)
    return false
  end

  return true
end

--- @param comment Comment
--- @param conversation GroupedComment
local function edit_comment_body(comment, conversation)
  local prompt = '<!-- Change your comment and press ' .. config.s.keymaps.comment.send_comment .. ': -->'

  utils.edit_comment(
    comment.id,
    prompt,
    vim.split(prompt .. '\n' .. comment.body, '\n'),
    config.s.keymaps.comment.send_comment,
    function(input)
      local progress = utils.new_progress_report('Updating comment...', vim.fn.bufnr())
      gh.update_comment(comment.id, input, function(resp)
        if resp['errors'] == nil then
          progress('success')
          comment.body = resp.body
          conversation.content = comments_utils.prepare_content(conversation.comments)
          M.load_comments_on_current_buffer()
        else
          progress('failed')
        end
      end)
    end
  )
end

M.update_comment = function(opts)
  -- on_comment('update', opts, function(conversations_list, comment, idx)
  --   edit_comment_body(comment, conversations_list[idx])
  -- end)
end

M.load_comments_on_buffer_by_filename = function(bufnr, filename)
  vim.schedule(function()
    config.log('load_comments_on_buffer filename', filename)
    local comments_list = vim.b[bufnr].guh_comments
    if comments_list and comments_list[filename] ~= nil then
      local diagnostics = {}
      for _, comment in pairs(comments_list[filename]) do
        if #comment.comments > 0 then
          config.log('comment to diagnostics', comment)
          table.insert(diagnostics, {
            lnum = comment.line - 1,
            col = 0,
            message = comment.content,
            severity = severity.INFO,
            source = 'guh.nvim',
          })
        end
      end

      vim.diagnostic.set(vim.api.nvim_create_namespace('guh.comments'), bufnr, diagnostics, {})
    end
  end)
end

return M
