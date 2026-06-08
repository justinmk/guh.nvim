local state = require('guh.state')

local M = {}

local overlay_ns = vim.api.nvim_create_namespace('guh.info_overlay')
local flash_ns = vim.api.nvim_create_namespace('guh.flash')

--- Flashes the given region so the user can see the target of an action.
---
--- If `start`/`end_` are integers, the region is treated as linewise (regtype="V").
---
--- @param buf integer
--- @param start integer|[integer, integer]
--- @param end_ integer|[integer, integer]
function M.hl_flash(buf, start, end_)
  local linewise = type(start) == 'number'
  vim.hl.range(buf, flash_ns, 'Visual', linewise and { start, 0 } or start, linewise and { end_, 0 } or end_, {
    regtype = linewise and 'V' or 'v',
    priority = 300, -- Overrule diffs.nvim: https://github.com/barrettruth/diffs.nvim/blob/d280baf3e937a487038766f51156dd41ceb0f8e7/lua/diffs/config.lua#L124-L129
    timeout = 200,
  })
end

--- Shared `nvim_echo` notification id. Re-using it makes successive emits
--- update the same notification in place, so progress events from different
--- callers (e.g. <CR>'s "Loading..." and the real work's progress) collapse
--- into one row.
local progress_echo_id = nil ---@type integer?

--- Builds an argv that runs `string.format(cmdstring, ...)` through a shell.
---
--- The purpose of this is to linearize a bunch of `cmd1 && cmd2 && …` shell commands into one terminal invocation.
---
--- TODO: this would not be needed if Nvim allowed appending-to a buftype=terminal buffer.
---
--- @param cmdstring string `string.format`-style script: "cmd1 && cmd2 && …"
--- @param ... string|number values to quote and substitute into `cmdstring`.
--- @return string[] argv
function M.shell_cmd(cmdstring, ...)
  local shell, flag, q
  if vim.fn.has('win32') == 1 then
    shell, flag, q = 'cmd.exe', '/c', '"'
  else
    shell, flag, q = 'sh', '-c', "'"
  end
  local args = { ... }
  for i, v in ipairs(args) do
    args[i] = q .. tostring(v) .. q
  end
  return { shell, flag, cmdstring:format(unpack(args)) }
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
---   - bare commit SHA (7-40 hex chars, must contain a-f): `"a1b2c3d"`
---   - GitHub URL: `"https://github.com/owner/repo/pull/13"`, `"…/issues/13"`, `"…/commit/<sha>"`
---   - Repo URL: `"https://github.com/owner/repo"`
---   - slug: `"owner/repo#13"`, or bare repo slug `"owner/repo"`.
---   - guh URI: `"guh://owner/repo/pr/13"`, `"guh://owner/repo/issue/13"`, `"guh://owner/repo/commit/<sha>"`, …
---
--- @param arg string
--- @return { owner?: string, repo?: string, id?: integer, sha?: string, is_pr?: boolean }?
function M.parse_target(arg)
  arg = vim.trim(arg or '')
  local owner, repo, num, sha, feat

  owner, repo, num = arg:match('^https?://github%.com/([^/]+)/([^/]+)/pull/(%d+)')
  if owner then
    return { owner = owner, repo = repo, id = tonumber(num), is_pr = true }
  end
  owner, repo, num = arg:match('^https?://github%.com/([^/]+)/([^/]+)/issues/(%d+)')
  if owner then
    return { owner = owner, repo = repo, id = tonumber(num), is_pr = false }
  end
  owner, repo, sha = arg:match('^https?://github%.com/([^/]+)/([^/]+)/commit/(%x+)')
  if owner then
    return { owner = owner, repo = repo, sha = sha }
  end
  -- Bare GitHub repo URL (with optional trailing slash) -> status view for that repo.
  owner, repo = arg:match('^https?://github%.com/([^/]+)/([^/]+)/?$')
  if owner then
    return { owner = owner, repo = repo }
  end

  owner, repo, sha = arg:match('^guh://([%w%._-]+)/([%w%._-]+)/commit/(%x+)$')
  if owner then
    return { owner = owner, repo = repo, sha = sha }
  end
  owner, repo, feat, num = arg:match('^guh://([%w%._-]+)/([%w%._-]+)/(%w+)/(%d+)$')
  if owner then
    local is_pr = (feat == 'pr' or feat == 'prdiff') or nil
    return { owner = owner, repo = repo, id = tonumber(num), is_pr = is_pr }
  end

  owner, repo, num = arg:match('^([%w%._-]+)/([%w%._-]+)#(%d+)$')
  if owner then
    return { owner = owner, repo = repo, id = tonumber(num) }
  end

  -- Bare "owner/name" slug (no id) -> status view for that repo.
  owner, repo = arg:match('^([%w%._-]+)/([%w%._-]+)$')
  if owner then
    return { owner = owner, repo = repo }
  end

  num = arg:match('^#(%d+)$')
  if num then
    return { id = tonumber(num) }
  end

  -- Bare commit SHA: 7-40 hex chars with at least one a-f letter (to disambiguate from numeric PR/issue IDs).
  if arg:match('^[%da-fA-F]+$') and #arg >= 7 and #arg <= 40 and arg:match('[a-fA-F]') then
    return { sha = arg }
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

--- Appends a debug log entry to `stdpath('log')/guh.log` when
--- `vim.g.guh_debug` is true. No-op otherwise.
---
--- @param key string
--- @param message any
function M.log(key, message)
  if not vim.g.guh_debug then
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

--- Returns the named `b:guh` fields in order, as multiple return-values, or emits an error and returns nil if
--- a required `b:guh` field is missing.
---
--- @param required string[] field names that must be non-nil on `b:guh`.
--- @param errmsg? string Defaults to "Not in a guh:// buffer".
--- @return any ...
function M.require_b_guh(required, errmsg)
  local b_guh = vim.b.guh or {}
  local vals = {}
  for i, k in ipairs(required) do
    if b_guh[k] == nil then
      M.msg(errmsg or 'Not in a guh:// buffer', vim.log.levels.ERROR)
      return
    end
    vals[i] = b_guh[k]
  end
  return unpack(vals)
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
--- @param mode string|string[] Mode name, or list thereof.
--- @param extra? table extra keymap opts (e.g. `{ nowait = true }`).
function M.map_default(buf, mode, lhs, rhs_plug, desc, extra)
  local modes = type(mode) == 'table' and mode or { mode }
  for _, m in ipairs(modes) do
    local has = vim.api.nvim_buf_call(buf, function()
      return vim.fn.hasmapto(rhs_plug, m) ~= 0
    end)
    if not has then
      local opts = vim.tbl_extend('keep', extra or {}, {
        buffer = buf,
        remap = true,
        silent = true,
        desc = desc,
      })
      vim.keymap.set(m, lhs, rhs_plug, opts)
    end
  end
end

--- Defines buffer-local defaults for the global `<Plug>(guh-…)` mappings, if necessary.
--- These defaults are shared across all `guh://*` views (status, PR, issue, prdiff, prcomments).
---
--- @param buf integer
function M.set_default_keymaps(buf)
  -- "Global" (buffer-relative) VIEW actions:
  M.map_default(buf, 'n', 'R', '<Plug>(guh-refresh)', 'Refresh this guh:// buffer')
  M.map_default(buf, 'n', 'dd', '<Plug>(guh-diff)', 'View the PR diff')
  M.map_default(buf, 'n', 'dl', '<Plug>(guh-logs)', 'View the CI logs for this PR')
  M.map_default(buf, 'n', ']f', '<Plug>(guh-next-commit)', 'View the next PR commit')
  M.map_default(buf, 'n', '[f', '<Plug>(guh-prev-commit)', 'View the previous PR commit')
  M.map_default(buf, 'n', 'g?', '<Plug>(guh-help)', 'Show guh-mappings help', { nowait = true })

  -- "Global" (buffer-relative) UPDATE actions:
  M.map_default(buf, 'n', 'cC', '<Plug>(guh-comment-overview)', 'Comment on PR/issue overview')
  M.map_default(buf, 'n', 'cM', '<Plug>(guh-merge)', 'Merge PR')
  M.map_default(buf, 'n', 'cR', '<Plug>(guh-review)', 'Review PR (approve/request-changes/comment)')
  M.map_default(buf, 'n', 'c:', '<Plug>(guh-edit)', 'Edit PR/issue properties (`gh pr edit`, `gh issue edit`)')

  -- "Local" (cursor-relative) actions:
  M.map_default(buf, 'n', 'cc', '<Plug>(guh-comment)', 'Comment on PR or diff')
  M.map_default(buf, 'x', 'c', '<Plug>(guh-comment)', 'Comment on PR or diff')
  M.map_default(buf, 'n', 'cr', '<Plug>(guh-thread)', 'Reply-to or Resolve a comment thread')
  M.map_default(buf, 'n', '<Enter>', '<Plug>(guh-open)', 'Open :Guh target at cursor')
  M.map_default(buf, 'n', '<C-W><Enter>', '<Plug>(guh-open-split)', 'Open :Guh target at cursor in a split')
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

--- Replaces `buf` contents with `lines` and sets the buffer as non-writable scratch
--- (buftype=nofile, 'nomodifiable', 'readonly').
---
--- @param buf integer
--- @param lines string[]
--- @param ft string filetype to apply.
function M.buf_set_readonly_lines(buf, lines, ft)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = ft
end

--- Overwrites the current :terminal buffer with the given cmd.
---
--- The buffer must have been initialized via `state.init_buf()` (`b:guh` is used to re-apply
--- the `guh://…` name on term exit, since Nvim stomps it).
---
--- @param buf integer (must have `b:guh` set by `state.init_buf()`)
--- @param cmd string[]
--- @param on_done? fun()
function M.run_term_cmd(buf, cmd, on_done)
  -- Fail fast if b:guh is invalid (init_buf() wasn't called?).
  local b_guh = vim.b[buf].guh
  assert(b_guh and b_guh.feat and b_guh.bufkey, ('run_term_cmd: invalid b:guh on buf %d'):format(buf))
  local progress = M.new_progress_report('Loading...', buf)
  progress('running')
  vim.schedule(function()
    local isempty = 1 == vim.fn.line('$') and '' == vim.fn.getline(1)
    assert(isempty or not vim.api.nvim_buf_is_loaded(buf) or (vim.o.buftype == 'terminal' and not not vim.b[buf].guh))
    vim.o.modifiable = true
    vim.o.modified = false
    vim.fn.jobstart(cmd, {
      term = true,
      env = {
        GH_PAGER = 'cat',
        PAGER = 'cat',
      },
      on_exit = function()
        local ns = vim.api.nvim_get_namespaces()['nvim.terminal.exitmsg']
        if ns and vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
        state.set_buf_name(buf, b_guh.feat, b_guh.bufkey)
        if on_done then
          on_done()
        end
        progress('success')
      end,
    })
  end)
end

--- Shows an info overlay message above line 1 of the given buffer.
--- Renders as a virtual line (extmark), so it scrolls with content and
--- never covers buffer text. Pass `msg=nil` to clear.
---
--- @param buf integer
--- @param msg? string|[string,string?][][] Message, or `nil` to clear the overlay.
--- @param hl? string highlight group (default 'Comment').
function M.show_info_overlay(buf, msg, hl)
  assert(type(msg) == 'string' or not hl)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, overlay_ns, 0, -1)
  local virt_lines = type(msg) == 'string' and { { { msg, hl or 'Comment' } } } or msg
  if msg then
    vim.api.nvim_buf_set_extmark(buf, overlay_ns, 0, 0, {
      virt_lines_above = true,
      virt_lines = virt_lines,
    })
  end
end

return M
