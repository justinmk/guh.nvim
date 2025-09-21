local comments = require('guh.comments')
local config = require('guh.config')
local gh = require('guh.gh')
local pr_commands = require('guh.pr_commands')
local pr_utils = require('guh.pr_utils')
local state = require('guh.state')
local utils = require('guh.utils')

local M = {}

local function construct_mappings(diff_content, cb)
  utils.get_git_root(function(git_root)
    local current_filename = nil
    local current_line_in_file = 0

    for line_num = 1, #diff_content do
      local line = diff_content[line_num]

      if line:match('^%-%-%-') then
        do
        end -- this shouldn't become line
      elseif line:match('^+++') then
        current_filename = line:match('^+++%s*(.+)')
        current_filename = git_root .. '/' .. current_filename:gsub('^b/', '')
      elseif line:sub(1, 2) == '@@' then
        local pos = vim.split(line, ' ')[3]
        local lineno = tonumber(vim.split(pos, ',')[1])
        if lineno then
          current_line_in_file = lineno
        end
      elseif current_filename then
        if state.filename_line_to_diff_line[current_filename] == nil then
          state.filename_line_to_diff_line[current_filename] = {}
        end
        state.filename_line_to_diff_line[current_filename][current_line_in_file] = line_num

        state.diff_line_to_filename_line[line_num] = { current_filename, current_line_in_file }
        if line:sub(1, 1) ~= '-' then
          current_line_in_file = current_line_in_file + 1
        end
      end
    end

    cb()
  end)
end

local function open_file_from_diff(open_command)
  return function()
    pr_utils.get_checked_out_pr(function(checked_out_pr)
      if checked_out_pr == nil then
        utils.notify('No PR to work with.', vim.log.levels.WARN)
        return
      end

      vim.schedule(function()
        local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

        local fnpair = state.diff_line_to_filename_line[cursor_line]
        local file_path = fnpair[1]
        local line_in_file = fnpair[2]
        vim.cmd(open_command .. ' ' .. file_path)
        vim.api.nvim_win_set_cursor(0, { line_in_file, 0 })
      end)
    end)
  end
end

function M.load_pr_diff()
  pr_utils.get_selected_pr(function(selected_pr)
    if selected_pr == nil then
      utils.notify('No PR selected/checked out', vim.log.levels.WARN)
      return
    end

    local progress = utils.new_progress_report('Loading PR diff')
    local buf = state.get_buf('diff', selected_pr.number)
    gh.get_pr_diff(selected_pr.number, function(diff_content)
      local diff_content_lines = vim.split(diff_content, '\n')
      construct_mappings(diff_content_lines, function()
        vim.schedule(function()
          buf = state.try_set_buf_name(buf, 'diff', selected_pr.number)
          state.diff_buffer_id = buf

          vim.bo[buf].buftype = 'nofile'
          vim.bo[buf].readonly = false
          vim.bo[buf].modifiable = true

          vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_content_lines)

          vim.bo[buf].filetype = 'diff'

          if config.s.diff_split then
            vim.api.nvim_command(config.s.diff_split)
          end
          vim.api.nvim_set_current_buf(buf)

          vim.bo[buf].readonly = true
          vim.bo[buf].modifiable = false

          if not utils.is_empty(config.s.keymaps.diff.open_file) then
            vim.api.nvim_buf_set_keymap(
              buf,
              'n',
              config.s.keymaps.diff.open_file,
              '',
              { desc = 'Open file', noremap = true, silent = true, callback = open_file_from_diff('edit') }
            )
          end

          if not utils.is_empty(config.s.keymaps.diff.open_file_tab) then
            vim.api.nvim_buf_set_keymap(
              buf,
              'n',
              config.s.keymaps.diff.open_file_tab,
              '',
              { desc = 'Open file in tab', noremap = true, silent = true, callback = open_file_from_diff('tabedit') }
            )
          end

          if not utils.is_empty(config.s.keymaps.diff.open_file_split) then
            vim.api.nvim_buf_set_keymap(
              buf,
              'n',
              config.s.keymaps.diff.open_file_split,
              '',
              { desc = 'Open file in split', noremap = true, silent = true, callback = open_file_from_diff('split') }
            )
          end

          if not utils.is_empty(config.s.keymaps.diff.open_file_vsplit) then
            vim.api.nvim_buf_set_keymap(
              buf,
              'n',
              config.s.keymaps.diff.open_file_vsplit,
              '',
              { desc = 'Open file in vertical split', noremap = true, silent = true, callback = open_file_from_diff('vsplit') }
            )
          end

          if not utils.is_empty(config.s.keymaps.diff.approve) then
            vim.api.nvim_buf_set_keymap(
              buf,
              'n',
              config.s.keymaps.diff.approve,
              '',
              { desc = 'Approve PR', noremap = true, silent = true, callback = pr_commands.approve_pr }
            )
          end

          if not utils.is_empty(config.s.keymaps.diff.request_changes) then
            vim.api.nvim_buf_set_keymap(
              buf,
              'n',
              config.s.keymaps.diff.request_changes,
              '',
              { desc = 'Request PR changes', noremap = true, silent = true, callback = pr_commands.request_changes_pr }
            )
          end

          progress('success')
          progress = utils.new_progress_report('Loading diff comments')
          comments.load_comments_only(selected_pr.number, function()
            comments.load_comments_on_diff_buffer(buf)
            progress('success')
          end)
        end)
      end)
    end)
  end)
end

function M.load_pr_diffview()
  pr_utils.get_selected_pr(function(selected_pr)
    if selected_pr == nil then
      utils.notify('No PR to work with.', vim.log.levels.WARN)
      return
    end

    local progress = utils.new_progress_report('Loading comments')
    comments.load_comments_only(selected_pr.number, function()
      progress('success')
      utils.get_git_merge_base(
        selected_pr.baseRefOid and selected_pr.baseRefOid or selected_pr.baseRefName,
        selected_pr.headRefOid,
        function(mergeBaseOid)
          vim.schedule(function()
            vim.cmd(string.format('DiffviewOpen %s..%s', mergeBaseOid, selected_pr.headRefOid))
          end)
        end
      )
    end)
  end)
end

return M
