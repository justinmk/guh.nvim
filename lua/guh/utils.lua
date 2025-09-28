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
  return value == nil or value == '' or value == 0 or #value == 0
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
--- @param buf integer
--- @return fun(status: 'running'|'success'|'failed'|'cancel', percent?: integer, fmt?: string, ...:any): nil
function M.new_progress_report(action, buf)
  local progress = { kind = 'progress', title = 'guh' }
  if buf then
    vim.bo[buf].busy = vim.bo[buf].busy + 1
  end

  return vim.schedule_wrap(function(status, percent, fmt, ...)
    local done = (status == 'failed' or status == 'success')
    progress.status = status
    progress.percent = not done and percent or nil
    progress.title = not done and progress.title or nil
    local msg = done and '' or ('%s %s'):format(action, (fmt or ''):format(...))
    progress.id = vim.api.nvim_echo({ { msg } }, status ~= 'running', progress)

    if buf then
      vim.bo[buf].busy = math.max(0, vim.bo[buf].busy - 1)
    end
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

function M.edit_comment(prnum, prompt, content, key_binding, callback)
  local buf = state.get_buf('comment', prnum)
  state.try_set_buf_name(buf, 'comment', prnum)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = true

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.cmd [[normal! G]]

  local function capture_input_and_close()
    local input_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if prompt ~= nil and input_lines[1] == prompt then
      table.remove(input_lines, 1)
    end
    local input = table.concat(input_lines, '\n')

    vim.cmd('bdelete')
    callback(input)
  end

  M.buf_keymap(buf, 'n', key_binding, '', capture_input_and_close)
  M.buf_keymap(buf, 'i', key_binding, '', capture_input_and_close)
end

--- Overwrites the current :terminal buffer with the given cmd.
--- @param cmd string[]
function M.run_term_cmd(buf, feat, id, cmd)
  vim.schedule(function()
    local isempty = 1 == vim.fn.line('$') and '' == vim.fn.getline(1)
    assert(isempty or vim.o.buftype == 'terminal')
    vim.o.modified = false
    vim.fn.jobstart(cmd, {
      term = true,
      on_exit = function()
        state.set_buf_name(buf, feat, id)
      end,
    })
  end)
end

return M
