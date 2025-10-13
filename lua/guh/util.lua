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
        error(result.stderr)
      end

      cb(result.stdout, result.stderr)
    end
  end)
end

function M.system(cmd, cb)
  vim.system(cmd, { text = true }, function(result)
    if type(cb) == 'function' then
      vim.schedule_wrap(cb)(result.stdout)
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

    if buf and vim.api.nvim_buf_is_valid(buf) then
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
    local function wrap_rhs(args)
      -- Fixup because apparently mappings don't get args?
      if not args then
        args = {}
        if vim.api.nvim_get_mode().mode:find('[vV]') then
          vim.fn.feedkeys(vim.keycode('<Esc>'), 'nx')
          args.line1 = vim.fn.line("'<")
          args.line2 = vim.fn.line("'>")
        else
          args.line1 = vim.fn.line('.')
          args.line2 = vim.fn.line('.')
        end
      end
      rhs(args)
    end
    vim.keymap.set(mode, lhs, type(rhs) == 'function' and wrap_rhs or rhs, opts)
  end
end

--- Overwrites the current :terminal buffer with the given cmd.
--- @param buf integer
--- @param feat Feat
--- @param id any
--- @param cmd string[]
--- @param on_done? fun()
function M.run_term_cmd(buf, feat, id, cmd, on_done)
  local progress = M.new_progress_report('Loading...', buf)
  progress('running')
  vim.schedule(function()
    local isempty = 1 == vim.fn.line('$') and '' == vim.fn.getline(1)
    assert(isempty or not vim.api.nvim_buf_is_loaded(buf) or (vim.o.buftype == 'terminal' and not not vim.b[buf].guh))
    vim.o.modifiable = true
    -- vim.api.nvim_buf_set_lines(buf, 1, 1, false, { 'Loading...' })
    vim.o.modified = false
    vim.fn.jobstart(cmd, {
      term = true,
      on_exit = function()
        state.set_buf_name(buf, feat, id)
        if on_done then
          on_done()
        end
        progress('success')
      end,
    })
  end)
end

local overlay_win = -1
local overlay_buf = -1

--- Shows an info overlay message in the given buffer.
--- Only one overlay is allowed globally.
--- Pass `msg=nil` to delete the current overlay.
---
--- @param buf integer
--- @param msg string? Message, or nil to delete the current overlay.
function M.show_info_overlay(buf, msg)
  local win = (vim.fn.win_findbuf(buf) or {})[1]
  local winvalid = vim.api.nvim_win_is_valid
  if not win then
    return -- Buffer not currently visible in any window.
  end
  -- vim.api.nvim_buf_clear_namespace(buf, overlay_ns, 0, -1)
  if not msg then
    if winvalid(overlay_win) then
      vim.api.nvim_win_close(overlay_win, true)
    end
    return -- If msg=nil, only clear the overlay.
  end

  -- Scratch buffer
  overlay_buf = vim.api.nvim_buf_is_valid(overlay_buf) and overlay_buf or vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(overlay_buf, 0, -1, false, { msg })

  local winconfig = {
    focusable = false,
    hide = false,
    relative = 'win', -- Anchor to window
    win = win,
    row = 0,
    col = 2,
    width = math.max(1, vim.api.nvim_win_get_width(win) - 2),
    height = 1,
    style = 'minimal',
    border = 'none',
  }
  overlay_win = winvalid(overlay_win) and overlay_win or vim.api.nvim_open_win(overlay_buf, false, winconfig)
  vim.api.nvim_win_set_config(overlay_win, winconfig)
  vim.wo[overlay_win].winhighlight = 'Normal:Comment'
end

return M
