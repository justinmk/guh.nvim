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
    local filename_line_to_diff_line = {}
    local diff_line_to_filename_line = {}

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
        if filename_line_to_diff_line[current_filename] == nil then
          filename_line_to_diff_line[current_filename] = {}
        end
        filename_line_to_diff_line[current_filename][current_line_in_file] = line_num

        diff_line_to_filename_line[line_num] = { current_filename, current_line_in_file }
        if line:sub(1, 1) ~= '-' then
          current_line_in_file = current_line_in_file + 1
        end
      end
    end

    cb(filename_line_to_diff_line, diff_line_to_filename_line)
  end)
end

local function open_file_from_diff()
  return function()
    pr_utils.get_checked_out_pr(function(checked_out_pr)
      if checked_out_pr == nil then
        utils.notify('No PR to work with.', vim.log.levels.WARN)
        return
      end

      vim.schedule(function()
        local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

        local current_buf = vim.api.nvim_get_current_buf()
        local fnpair = vim.b[current_buf].diff_line_to_filename_line[cursor_line]
        if fnpair and type(fnpair) == 'table' then
          local file_path = fnpair[1]
          local line_in_file = fnpair[2]
          vim.cmd.edit(file_path)
          vim.api.nvim_win_set_cursor(0, { line_in_file, 0 })
        else
          utils.notify('No file associated with this line.', vim.log.levels.WARN)
        end
      end)
    end)
  end
end

--- Use the DiffView plugin to view a pr diff.
--- @param pr PullRequest
local function view_diffview(pr)
  local progress = utils.new_progress_report('Loading PR diff', vim.fn.bufnr())
  comments.load_comments_only(pr.number, function()
    progress('success')
    utils.get_git_merge_base(pr.baseRefOid and pr.baseRefOid or pr.baseRefName, pr.headRefOid, function(mergeBaseOid)
      vim.schedule(function()
        vim.cmd(string.format('DiffviewOpen %s..%s', mergeBaseOid, pr.headRefOid))
      end)
    end)
  end)
end

--- @param strategy? 'builtin'|'diffview' # Diff viewer
function M.load_pr_diff(strategy)
  pr_utils.get_selected_pr(function(pr)
    if pr == nil then
      utils.notify('No PR selected', vim.log.levels.WARN)
      return
    elseif strategy == 'diffview' then
      view_diffview(pr)
    end

    local progress = utils.new_progress_report('Loading PR diff', vim.fn.bufnr())
    local buf = state.get_buf('diff', pr.number)
    gh.get_pr_diff(pr.number, function(diff_content)
      local diff_content_lines = vim.split(diff_content, '\n')
      construct_mappings(diff_content_lines, function(filename_line_to_diff_line, diff_line_to_filename_line)
        vim.schedule(function()
          buf = state.try_set_buf_name(buf, 'diff', pr.number)
          state.diff_buffer_id = buf

          vim.bo[buf].buftype = 'nofile'
          vim.bo[buf].readonly = false
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_content_lines)
          vim.bo[buf].filetype = 'diff'

          vim.bo[buf].readonly = true
          vim.bo[buf].modifiable = false

          -- Store mappings in buffer-local variables
          vim.b[buf].filename_line_to_diff_line = filename_line_to_diff_line
          vim.b[buf].diff_line_to_filename_line = diff_line_to_filename_line

          local conf = config.s.keymaps.diff
          utils.buf_keymap(buf, 'n', conf.open_file, 'Open file', open_file_from_diff('edit'))
          utils.buf_keymap(buf, 'n', conf.comment, 'Comment on current line or range', '<cmd>GuhComment<cr>')
          utils.buf_keymap(buf, 'n', conf.open_file_tab, 'Open file in tab', open_file_from_diff('tabedit'))
          utils.buf_keymap(buf, 'n', conf.open_file_split, 'Open file in split', open_file_from_diff('split'))
          utils.buf_keymap(
            buf,
            'n',
            conf.open_file_vsplit,
            'Open file in vertical split',
            open_file_from_diff('vsplit')
          )
          utils.buf_keymap(buf, 'n', conf.approve, 'Approve PR', pr_commands.approve_pr)
          utils.buf_keymap(buf, 'n', conf.request_changes, 'Request PR changes', pr_commands.request_changes_pr)

          progress('success')
          progress = utils.new_progress_report('Loading diff comments', vim.fn.bufnr())
          comments.load_comments_only(pr.number, function()
            comments.load_comments_on_diff_buffer(buf)
            progress('success')
          end)
        end)
      end)
    end)
  end)
end

return M
