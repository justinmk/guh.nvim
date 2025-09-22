local comments_utils = require('guh.comments_utils')
local config = require('guh.config')
local gh = require('guh.gh')
local pr_utils = require('guh.pr_utils')
local state = require('guh.state')
local utils = require('guh.utils')

local M = {}

local function load_comments_to_quickfix_list()
  local qf_entries = {}

  local filenames = {}
  for fn in pairs(state.comments_list) do
    table.insert(filenames, fn)
  end
  table.sort(filenames)

  for _, filename in pairs(filenames) do
    local comments_in_file = state.comments_list[filename]

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
  pr_utils.get_checked_out_pr(function(checked_out_pr)
    if checked_out_pr == nil then
      utils.notify('No PR to work with.', vim.log.levels.WARN)
      return
    end

    local progress = utils.new_progress_report('Loading comments')
    gh.load_comments(checked_out_pr.number, function(comments_list)
      state.comments_list = comments_list
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
    state.comments_list = comments_list
    cb()
  end)
end

M.load_comments_on_current_buffer = function()
  vim.schedule(function()
    local current_buffer = vim.api.nvim_get_current_buf()
    M.load_comments_on_buffer(current_buffer)
  end)
end

M.load_comments_on_buffer = function(bufnr)
  if bufnr == state.diff_buffer_id then
    M.load_comments_on_diff_buffer(bufnr)
    return
  end

  local buf_name = vim.api.nvim_buf_get_name(bufnr)

  if M.is_in_diffview(buf_name) then
    M.get_diffview_filename(buf_name, function(filename)
      M.load_comments_on_buffer_by_filename(bufnr, filename)
    end)

    return
  end

  pr_utils.is_pr_checked_out(function(is_pr_checked_out)
    if not is_pr_checked_out then
      return
    end

    M.load_comments_on_buffer_by_filename(bufnr, buf_name)
  end)
end

M.load_comments_on_diff_buffer = function(bufnr)
  config.log('load_comments_on_diff_buffer')
  local diagnostics = {}

  for filename, comments in pairs(state.comments_list) do
    if vim.b[bufnr].filename_line_to_diff_line[filename] then
      for _, comment in pairs(comments) do
        local diff_line = vim.b[bufnr].filename_line_to_diff_line[filename][comment.line]
        if diff_line and #comment.comments > 0 then
          table.insert(diagnostics, {
            lnum = diff_line - 1,
            col = 0,
            message = comment.content,
            severity = vim.diagnostic.severity.INFO,
            source = 'guh.nvim',
          })
        end
      end
    end
  end

  vim.schedule(function()
    vim.diagnostic.set(vim.api.nvim_create_namespace('guh.diff'), bufnr, diagnostics, {})
  end)
end

M.get_conversations = function(current_filename, current_line)
  --- @type GroupedComment[]
  local conversations = {}
  if state.comments_list[current_filename] ~= nil then
    for _, comment in pairs(state.comments_list[current_filename]) do
      if current_line == comment.line then
        table.insert(conversations, comment)
      end
    end
  end
  return conversations
end

local function get_current_filename_and_line(start_line, end_line, cb)
  vim.schedule(function()
    local current_buf = vim.api.nvim_get_current_buf()
    local current_start_line, current_line

    if start_line and end_line then
      current_start_line = start_line
      current_line = end_line
    else
      current_start_line = vim.fn.line("'<")
      current_line = vim.fn.line("'>")

      if current_line == 0 then
        current_start_line = vim.api.nvim_win_get_cursor(0)[1]
        current_line = current_start_line
      end
    end

    local current_filename = vim.api.nvim_buf_get_name(current_buf)

    if current_buf == state.diff_buffer_id then
      local info = vim.b[current_buf].diff_line_to_filename_line[current_start_line]
      current_filename = info[1]
      current_start_line = info[2]
      info = vim.b[current_buf].diff_line_to_filename_line[current_line]
      current_line = info[2]
    elseif M.is_in_diffview(current_filename) then
      M.get_diffview_filename(current_filename, function(filename)
        cb(filename, current_start_line, current_line)
      end)
    elseif not state.selected_PR then
      pr_utils.is_pr_checked_out(function(is_pr_checked_out)
        pr_utils.get_checked_out_pr(function(checked_out_pr)
          if not is_pr_checked_out then
            if checked_out_pr then
              utils.notify('Command canceled because of PR check out.', vim.log.levels.WARN)
            end
            cb(nil, nil, nil)
            return
          end
          cb(current_filename, current_start_line, current_line)
        end)
      end)
    end

    cb(current_filename, current_start_line, current_line)
  end)
end

--- Comments on a diff line/range.
M.comment_on_line = function(start_line, end_line)
  pr_utils.get_selected_pr(function(selected_pr)
    if selected_pr == nil then
      utils.notify('No PR selected/checked out', vim.log.levels.WARN)
      return
    end

    get_current_filename_and_line(
      start_line,
      end_line,
      function(current_filename, current_start_line, current_line)
        if current_filename == nil or current_start_line == nil or current_line == nil then
          utils.notify('You are on a branch without PR.', vim.log.levels.WARN)
          return
        end

        utils.get_git_root(function(git_root)
          if current_filename:sub(1, #git_root) ~= git_root then
            utils.notify('File is not under git folder.', vim.log.levels.ERROR)
            return
          end

          vim.schedule(function()
            local conversations = {}
            if current_start_line == current_line then
              conversations = M.get_conversations(current_filename, current_line)
            end

            local prompt = '<!-- Type your '
              .. (#conversations > 0 and 'reply' or 'comment')
              .. ' and press '
              .. config.s.keymaps.comment.send_comment
              .. ': -->'

            utils.edit_comment(
              999,
              nil,
              prompt,
              { prompt, '' },
              config.s.keymaps.comment.send_comment,
              function(input)
                --- @param grouped_comment GroupedComment
                local function reply(grouped_comment)
                  local progress = utils.new_progress_report('Sending reply')
                  gh.reply_to_comment(state.selected_PR.number, input, grouped_comment.id, function(resp)
                    if resp['errors'] == nil then
                      progress('success', nil, 'Reply sent')
                      local new_comment = comments_utils.convert_comment(resp)
                      table.insert(grouped_comment.comments, new_comment)
                      grouped_comment.content = comments_utils.prepare_content(grouped_comment.comments)
                      M.load_comments_on_current_buffer()
                    else
                      progress('failed', nil, 'Failed to reply to comment')
                    end
                  end)
                end

                if #conversations == 1 then
                  reply(conversations[1])
                elseif #conversations > 1 then
                  vim.ui.select(conversations, {
                    prompt = 'Select comment to reply to:',
                    format_item = function(comment)
                      return string.format('%s', vim.split(comment.content, '\n')[1])
                    end,
                  }, function(comment)
                    if comment ~= nil then
                      reply(comment)
                    end
                  end)
                else
                  if current_filename:sub(1, #git_root) == git_root then
                    local progress = utils.new_progress_report('Sending comment...')
                    gh.new_comment(
                      state.selected_PR,
                      input,
                      current_filename:sub(#git_root + 2),
                      current_start_line,
                      current_line,
                      function(resp)
                        if resp['errors'] == nil then
                          local new_comment = comments_utils.convert_comment(resp)
                          --- @type GroupedComment
                          local new_comment_group = {
                            id = resp.id,
                            line = current_line,
                            start_line = current_start_line,
                            url = resp.html_url,
                            comments = { new_comment },
                            content = comments_utils.prepare_content({ new_comment }),
                          }
                          if state.comments_list[current_filename] == nil then
                            state.comments_list[current_filename] = { new_comment_group }
                          else
                            table.insert(state.comments_list[current_filename], new_comment_group)
                          end

                          progress('success', nil, 'Comment sent.')
                          M.load_comments_on_current_buffer()
                        else
                          progress('failed', nil, 'Failed to send comment.')
                        end
                      end
                    )
                  end
                end
              end
            )
          end)
        end)
      end)
  end)
end

local function validate_cur_filename(f)
  if f == nil then
    utils.notify('You are on a branch without PR.', vim.log.levels.WARN)
    return false
  end

  if f:match('guh://info/') then
    utils.notify('This command is for file comments. Use :GuhComment for PR comments.', vim.log.levels.WARN)
    return false
  end

  return true
end

M.open_comment = function(opts)
  get_current_filename_and_line(
    opts.range and opts.line1 or nil,
    opts.range and opts.line2 or nil,
    function(current_filename, _, current_line)
      if not validate_cur_filename(current_filename) then
        return
      end

      local conversations = M.get_conversations(current_filename, current_line)

      vim.schedule(function()
        if #conversations == 1 then
        vim.ui.open(conversations[1].url)
        elseif #conversations > 1 then
          vim.ui.select(conversations, {
            prompt = 'Select conversation to open in browser:',
            format_item = function(comment)
              return string.format('%s', vim.split(comment.content, '\n')[1])
            end,
          }, function(comment)
            if comment ~= nil then
            vim.ui.open(comment.url)
            end
          end)
        else
          utils.notify('No comments found on this line.', vim.log.levels.WARN)
        end
      end)
    end)
end

local function get_own_comments(current_filename, current_line, cb)
  local conversations = M.get_conversations(current_filename, current_line)
  gh.get_user(function(user)
    --- @type Comment[]
    local comments_list = {}
    --- @type GroupedComment[]
    local conversations_list = {}

    for _, convo in pairs(conversations) do
      for _, comment in pairs(convo.comments) do
        if comment.user == user then
          table.insert(comments_list, comment)
          table.insert(conversations_list, convo)
        end
      end
    end

    cb(comments_list, conversations_list)
  end)
end

--- @param comment Comment
--- @param conversation GroupedComment
local function edit_comment_body(comment, conversation)
  local prompt = '<!-- Change your comment and press ' .. config.s.keymaps.comment.send_comment .. ': -->'

  utils.edit_comment(
    comment.id,
    config.s.comment_split,
    prompt,
    vim.split(prompt .. '\n' .. comment.body, '\n'),
    config.s.keymaps.comment.send_comment,
    function(input)
      utils.notify('Updating comment...')
      gh.update_comment(comment.id, input, function(resp)
        if resp['errors'] == nil then
          utils.notify('Comment updated.')
          comment.body = resp.body
          conversation.content = comments_utils.prepare_content(conversation.comments)

          M.load_comments_on_current_buffer()
        else
          utils.notify('Failed to update the comment.', vim.log.levels.ERROR)
        end
      end)
    end
  )
end

--- @param opts table
--- @param fn fun(conversations_list: any, comment: any, idx?: integer)
local function on_comment(action, opts, fn)
  get_current_filename_and_line(
    opts.range and opts.line1 or nil,
    opts.range and opts.line2 or nil,
    function(current_filename, _, current_line)
      if not validate_cur_filename(current_filename) then
        return
      end

      get_own_comments(current_filename, current_line, function(comments_list, conversations_list)
        if #comments_list == 0 then
          utils.notify('No comments found.', vim.log.levels.WARN)
          return
        end

        vim.schedule(function()
          vim.ui.select(comments_list, {
            prompt = ('Select comment to %s:'):format(action),
            format_item = function(comment)
              return string.format('%s: %s', comment.updated_at, vim.split(comment.body, '\n')[1])
            end,
          }, function(comment, idx)
            if comment ~= nil then
              fn(conversations_list, comment, idx)
            end
          end)
        end)
      end)
    end
  )
end

M.update_comment = function(opts)
  on_comment('update', opts, function(conversations_list, comment, idx)
    edit_comment_body(comment, conversations_list[idx])
  end)
end

M.delete_comment = function(opts)
  on_comment('delete', opts, function(conversations_list, comment, idx)
    local progress = utils.new_progress_report('Deleting comment...')
    gh.delete_comment(comment.id, function()
      local function is_non_deleted_comment(c)
        return c.id ~= comment.id
      end

      local convo = conversations_list[idx]
      convo.comments = utils.filter_array(convo.comments, is_non_deleted_comment)
      convo.content = comments_utils.prepare_content(convo.comments)

      progress('success')
      M.load_comments_on_current_buffer()
    end)
  end)
end

M.is_in_diffview = function(buf_name)
  return string.sub(buf_name, 1, 11) == 'diffview://'
end

M.get_diffview_filename = function(buf_name, cb)
  local view = require('diffview.lib').get_current_view()
  local file = view:infer_cur_file()
  if file then
    pr_utils.get_selected_pr(function(selected_pr)
      if selected_pr == nil then
        utils.notify('No PR selected/checked out', vim.log.levels.WARN)
        return
      end

      local full_name = file.absolute_path

      config.log('get_diffview_filename. buf_name', buf_name)
      config.log('get_diffview_filename. full_name', full_name)
      config.log('get_diffview_filename. selected_pr.headRefOid', selected_pr.headRefOid)

      local commit_abbrev = selected_pr.headRefOid:sub(1, 11)

      local found = string.find(buf_name, commit_abbrev, 1, true)
      if found then
        cb(full_name)
      end
    end)
  end
end

M.load_comments_on_buffer_by_filename = function(bufnr, filename)
  vim.schedule(function()
    config.log('load_comments_on_buffer filename', filename)
    if state.comments_list[filename] ~= nil then
      local diagnostics = {}
      for _, comment in pairs(state.comments_list[filename]) do
        if #comment.comments > 0 then
          config.log('comment to diagnostics', comment)
          table.insert(diagnostics, {
            lnum = comment.line - 1,
            col = 0,
            message = comment.content,
            severity = vim.diagnostic.severity.INFO,
            source = 'guh.nvim',
          })
        end
      end

      vim.diagnostic.set(vim.api.nvim_create_namespace('guh.comments'), bufnr, diagnostics, {})
    end
  end)
end

--- Performs a PR-level comment or diff line/range comment.
M.comment = function(opts, on_success)
  if opts.bang and opts.range then
    utils.notify('Cannot use bang and range together.', vim.log.levels.ERROR)
    return
  end

  if opts.bang then
    -- PR-level comment
    pr_utils.get_selected_pr(function(selected_pr)
      if selected_pr == nil then
        utils.notify('No PR selected/checked out', vim.log.levels.WARN)
        return
      end

      vim.schedule(function()
        local prompt = '<!-- Type your PR comment and press '
          .. config.s.keymaps.comment.send_comment
          .. ' to comment: -->'

        utils.edit_comment(
          selected_pr.number,
          config.s.comment_split,
          prompt,
          { prompt, '' },
          config.s.keymaps.comment.send_comment,
          function(input)
            utils.notify('Sending comment...')

            gh.new_pr_comment(state.selected_PR, input, function(resp)
              if resp ~= nil then
                utils.notify('Comment sent.')
                if type(on_success) == 'function' then
                  on_success()
                end
              else
                utils.notify('Failed to send comment.', vim.log.levels.WARN)
              end
            end)
          end
        )
      end)
    end)
  else
    -- Diff line-comment
    if opts.range then
      M.comment_on_line(opts.line1, opts.line2)
    else
      M.comment_on_line()
    end
  end
end

return M
