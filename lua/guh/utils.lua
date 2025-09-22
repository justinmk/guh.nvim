local config = require('guh.config')
local state = require('guh.state')

local M = {}

function M.system_str(cmd, cb)
  local cmd_split = vim.split(cmd, ' ')
  vim.system(cmd_split, { text = true }, function(result)
    if type(cb) == 'function' then
      if result.code ~= 0 and #result.stderr > 0 then
        config.log('system_str error', result.stderr)
        M.notify(result.stderr, vim.log.levels.ERROR)
      end

      cb(result.stdout, result.stderr)
    end
  end)
end

function M.system(cmd, cb)
  vim.system(cmd, { text = true }, function(result)
    if type(cb) == 'function' then
      cb(result.stdout)
    end
  end)
end

function M.filter_array(arr, condition)
  local result = {}
  for _, v in ipairs(arr) do
    if condition(v) then
      table.insert(result, v)
    end
  end
  return result
end

function M.is_empty(value)
  if value == nil or vim.fn.empty(value) == 1 then
    return true
  end
  return false
end

function M.get_git_root(cb)
  M.system_str('git rev-parse --show-toplevel', function(result)
    cb(vim.split(result, '\n')[1])
  end)
end

function M.get_git_merge_base(baseCommitId, headCommitId, cb)
  M.system_str('git merge-base ' .. baseCommitId .. ' ' .. headCommitId, function(result)
    cb(vim.split(result, '\n')[1])
  end)
end

function M.get_current_git_branch_name(cb)
  M.system_str('git branch --show-current', function(result)
    cb(vim.split(result, '\n')[1])
  end)
end

function M.notify(message, level)
  vim.schedule(function()
    vim.notify(message, level)
  end)
end

--- @param action string
--- @return fun(status: 'running'|'success'|'failed'|'cancel', percent?: integer, fmt?: string, ...:any): nil
function M.new_progress_report(action)
  local progress = { kind = 'progress', title = 'guh' }

  return vim.schedule_wrap(function(status, percent, fmt, ...)
    progress.status = status
    progress.percent = percent
    local msg = ('%s %s'):format(action, (fmt or ''):format(...))
    progress.id = vim.api.nvim_echo({ { msg } }, status ~= 'running', progress)
    -- Force redraw to show installation progress during startup
    vim.cmd.redraw({ bang = true })
  end)
end

function M.buf_keymap(buf, mode, lhs, desc, rhs)
  if not M.is_empty(lhs) then
    local opts = {}
    opts.desc = opts.desc == nil and desc or opts.desc
    opts.noremap = opts.noremap == nil and true or opts.noremap
    opts.silent = opts.silent == nil and true or opts.silent
    opts.buffer = buf
    vim.keymap.set(mode, lhs, rhs, opts)
  end
end

function M.get_comment(prnum, split_command, prompt, content, key_binding, callback)
  local buf = state.get_buf('comment', prnum)
  state.try_set_buf_name(buf, 'comment', prnum)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'markdown'

  if split_command then
    vim.api.nvim_command(split_command)
  end
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local function capture_input_and_close()
    local input_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if prompt ~= nil and input_lines[1] == prompt then
      table.remove(input_lines, 1)
    end
    local input = table.concat(input_lines, '\n')

    vim.cmd('bwipeout')
    callback(input)
  end

  M.buf_keymap(buf, 'n', key_binding, '', capture_input_and_close)
  M.buf_keymap(buf, 'i', key_binding, '', capture_input_and_close)
end

return M
