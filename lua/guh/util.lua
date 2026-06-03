local config = require('guh.config')
local state = require('guh.state')

local M = {}

--- Shared `nvim_echo` notification id. Re-using it makes successive emits
--- update the same notification in place, so progress events from different
--- callers (e.g. <CR>'s "Loading..." and the real work's progress) collapse
--- into one row.
local progress_echo_id = nil ---@type integer?

--- Runs a shell command (split on spaces) asynchronously via `vim.system`.
--- On non-zero exit with stderr: logs, notifies, and raises an error.
---
--- @deprecated Use `util.system()` instead.
---
--- @param cmd string Command string; split on spaces into argv.
--- @param cb? fun(stdout: string, stderr: string)
function M.system_str(cmd, cb)
  local cmd_split = vim.split(cmd, ' ')
  vim.system(cmd_split, { text = true }, function(result)
    if type(cb) == 'function' then
      if result.code ~= 0 and #result.stderr > 0 then
        M.log('system_str error', result.stderr)
        M.msg(result.stderr, vim.log.levels.ERROR)
        error(result.stderr)
      end

      cb(result.stdout, result.stderr)
    end
  end)
end

--- Runs a command asynchronously via `vim.system`. The callback is deferred (`vim.schedule_wrap`).
---
--- @param cmd string[] argv list.
--- @param cb? fun(stdout: string, stderr: string, code: integer)
function M.system(cmd, cb)
  vim.system(cmd, { text = true }, function(result)
    if type(cb) == 'function' then
      vim.schedule_wrap(cb)(result.stdout, result.stderr, result.code)
    end
  end)
end

--- Parses a :Guh argument. Accepts:
---   - bare number: `"13"`
---   - GitHub URL: `"https://github.com/owner/repo/pull/13"` or `"…/issues/13"`
---   - slug: `"owner/repo#13"`
---   - guh URI: `"guh://pr/owner/repo/13"`, `"guh://issue/owner/repo/13"`,
---     `"guh://diff/owner/repo/13"`
---
--- @param arg string
--- @return { owner?: string, repo?: string, id: integer, is_pr?: boolean }?
function M.parse_target(arg)
  arg = vim.trim(arg or '')
  local owner, repo, num, feat

  owner, repo, num = arg:match('^https?://github%.com/([^/]+)/([^/]+)/pull/(%d+)')
  if owner then
    return { owner = owner, repo = repo, id = tonumber(num), is_pr = true }
  end
  owner, repo, num = arg:match('^https?://github%.com/([^/]+)/([^/]+)/issues/(%d+)')
  if owner then
    return { owner = owner, repo = repo, id = tonumber(num), is_pr = false }
  end

  feat, owner, repo, num = arg:match('^guh://(%w+)/([%w%._-]+)/([%w%._-]+)/(%d+)$')
  if feat then
    local is_pr = (feat == 'pr' or feat == 'diff') or nil
    return { owner = owner, repo = repo, id = tonumber(num), is_pr = is_pr }
  end

  owner, repo, num = arg:match('^([%w%._-]+)/([%w%._-]+)#(%d+)$')
  if owner then
    return { owner = owner, repo = repo, id = tonumber(num) }
  end

  num = arg:match('^#(%d+)$')
  if num then
    return { id = tonumber(num) }
  end

  num = tonumber(arg)
  if num then
    return { id = num }
  end
  return nil
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

--- Appends a debug log entry to `stdpath('log')/guh.log` when
--- `config.s.debug` is true. No-op otherwise.
---
--- @param key string
--- @param message any
function M.log(key, message)
  if not config.s.debug then
    return
  end
  local log_file_name = vim.fn.stdpath('log') .. '/guh.log'
  local log_file = io.open(log_file_name, 'a')
  if not log_file then
    return
  end
  log_file:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. key .. ':\n')
  log_file:write(vim.inspect(message))
  log_file:write('\n\n')
  log_file:close()
end

--- Shows a notification prefixed with "guh:".
--- @param message string
--- @param level? integer one of `vim.log.levels.*`
function M.msg(message, level)
  vim.schedule(function()
    vim.notify(('guh: %s'):format(message), level)
  end)
end

--- @param action string
--- @param buf integer
--- @return fun(status: 'running'|'success'|'failed'|'cancel', percent?: integer, fmt?: string, ...:any): nil
function M.new_progress_report(action, buf)
  local progress = { kind = 'progress', title = 'guh' }
  local incremented = false
  if buf and not vim.in_fast_event() and buf > 0 then
    vim.bo[buf].busy = vim.bo[buf].busy + 1
    incremented = true
  end

  return vim.schedule_wrap(function(status, percent, fmt, ...)
    local done = (status == 'failed' or status == 'success' or status == 'cancel')
    progress.source = 'guh.nvim'
    progress.status = status
    progress.percent = not done and percent or nil
    progress.title = not done and progress.title or nil
    progress.id = progress_echo_id
    local msg = done and '' or ('%s %s'):format(action, (fmt or ''):format(...))
    progress_echo_id = vim.api.nvim_echo({ { msg } }, status ~= 'running', progress)
    if done then
      progress_echo_id = nil
    end

    -- Only decrement on done, and only if we incremented in the first place.
    if done and incremented and buf and vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].busy = math.max(0, vim.bo[buf].busy - 1)
      incremented = false
    end
  end)
end

--- Synchronously emits "Loading..." (or `label`) under a shared progress-id.
--- Returns a finalizer that emits `status` (default 'success') to dismiss.
---
--- @param label? string default: "Loading..."
--- @return fun(status?: 'success'|'failed'|'cancel')
function M.progress(label)
  progress_echo_id = vim.api.nvim_echo({ { label or 'Loading...' } }, false, {
    kind = 'progress',
    source = 'guh.nvim',
    title = 'guh',
    status = 'running',
    id = progress_echo_id,
  })
  return function(status)
    progress_echo_id = vim.api.nvim_echo({ { '' } }, false, {
      kind = 'progress',
      source = 'guh.nvim',
      status = status or 'success',
      id = progress_echo_id,
    })
    progress_echo_id = nil
  end
end

--- Sets a buffer-local `lhs` → `rhs_plug` mapping, unless the user already
--- mapped that `<Plug>` to a different key (per |hasmapto()|).
---
--- @param extra? table extra keymap opts (e.g. `{ nowait = true }`).
function M.map_default(buf, mode, lhs, rhs_plug, desc, extra)
  if vim.fn.hasmapto(rhs_plug, mode) ~= 0 then
    return
  end
  local opts = vim.tbl_extend('keep', extra or {}, {
    buffer = buf,
    remap = true,
    silent = true,
    desc = desc,
  })
  vim.keymap.set(mode, lhs, rhs_plug, opts)
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
        local region = vim.fn.getregionpos(vim.fn.getpos('v'), vim.fn.getpos('.'), {
          type = 'v',
          exclusive = false,
          eol = false,
        })
        args.line1 = region[1][1][2]
        args.line2 = region[#region][1][2]
        -- vim.fn.feedkeys(vim.keycode('<Esc>'), 'nx')
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
        local ns = vim.api.nvim_get_namespaces()['nvim.terminal.exitmsg']
        if ns and vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
        state.set_buf_name(buf, feat, id)
        if on_done then
          on_done()
        end
        progress('success')
      end,
    })
  end)
end

local overlay_ns = vim.api.nvim_create_namespace('guh.info_overlay')

--- Shows an info overlay message above line 1 of the given buffer.
--- Renders as a virtual line (extmark), so it scrolls with content and
--- never covers buffer text. Pass `msg=nil` to clear.
---
--- @param buf integer
--- @param msg string? Message, or nil to clear the overlay.
function M.show_info_overlay(buf, msg)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, overlay_ns, 0, -1)
  if msg then
    vim.api.nvim_buf_set_extmark(buf, overlay_ns, 0, 0, {
      virt_lines_above = true,
      virt_lines = { { { msg, 'Comment' } } },
    })
  end
end

return M
