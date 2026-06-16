local state = require('guh.state')

local M = {}

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
  -- Strip surrounding punctuation ("(#123).", "[owner/repo],"). Excludes `#`, `/`, `:`.
  arg = arg:gsub([[^[%(%)%[%]<>{}'"`,;%.!?]+]], ''):gsub([[[%(%)%[%]<>{}'"`,;%.!?]+$]], '')
  local owner, repo, num, sha, feat

  owner, repo, num = arg:match('https?://github%.com/([^/]+)/([^/]+)/pull/(%d+)')
  if owner then
    return { owner = owner, repo = repo, id = tonumber(num), is_pr = true }
  end
  owner, repo, num = arg:match('https?://github%.com/([^/]+)/([^/]+)/issues/(%d+)')
  if owner then
    return { owner = owner, repo = repo, id = tonumber(num), is_pr = false }
  end
  owner, repo, sha = arg:match('https?://github%.com/([^/]+)/([^/]+)/commit/(%x+)')
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
    local is_pr = ({ pr = true, prdiff = true, prcomments = true, prlogs = true, issue = false })[feat]
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

--- Appends a log entry to `stdpath('log')/guh.log` when `vim.g.guh_debug` is set. No-op otherwise.
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
    local hl = level == vim.log.levels.WARN and 'WarningMsg' or nil
    vim.api.nvim_echo({ { ('guh: %s'):format(message), hl } }, true, { err = level == vim.log.levels.ERROR })
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
  M.map_default(buf, 'n', ']f', '<Plug>(guh-next)', 'View the next PR commit / CI job')
  M.map_default(buf, 'n', '[f', '<Plug>(guh-prev)', 'View the previous PR commit / CI job')
  M.map_default(buf, 'n', 'g?', '<Plug>(guh-help)', 'Show guh-mappings help', { nowait = true })

  -- "Global" (buffer-relative) UPDATE actions:
  M.map_default(buf, 'n', 'cC', '<Plug>(guh-comment-top)', 'Comment on PR/issue overview')
  M.map_default(buf, 'n', 'cI', '<Plug>(guh-ci)', 'Rerun CI jobs')
  M.map_default(buf, 'n', 'cM', '<Plug>(guh-merge)', 'Merge PR')
  M.map_default(buf, 'n', 'cR', '<Plug>(guh-review)', 'Review PR (approve/request-changes/comment)')
  M.map_default(buf, 'n', 'c:', '<Plug>(guh-edit)', 'Edit PR/issue properties (`gh pr edit`, `gh issue edit`)')

  -- "Local" (cursor-relative) actions:
  M.map_default(buf, 'n', 'cc', '<Plug>(guh-comment)', 'Comment on PR or diff')
  M.map_default(buf, 'x', 'c', '<Plug>(guh-comment)', 'Comment on PR or diff')
  M.map_default(buf, 'n', 'cr', '<Plug>(guh-thread)', 'Reply-to or Resolve a comment thread')
  M.map_default(buf, 'n', 'cv', '<Plug>(guh-viewed)', 'Toggle "Viewed" state of the diff file at cursor')
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

--- Concurrently runs N commands and streams their stdout into a terminal buf in-order.
---
--- - Output of `cmds[1]` streams into the terminal as it arrives.
--- - Output of `cmds[i>1]` is buffered while a lower-index command is still streaming, then flushed
---   to the terminal in-order once the lower-index commands exit.
---
--- HACK: special-case `opts.term=true` for use with a single (interactive) cmd, until upstream fix: https://github.com/neovim/neovim/issues/40194
---
--- @param buf integer (must have `b:guh` set by `state.init_buf()`)
--- @param opts? { pty?: boolean, term?: boolean }
--- @param cmds string[][] List of commands.
--- @param on_done? fun()
function M.run_term_cmds(buf, opts, cmds, on_done)
  vim.validate('buf', buf, 'number')
  vim.validate('cmds', cmds, function(v)
    return type(v) == 'table' and #v > 0
  end, 'non-empty list')
  -- Fail fast if b:guh is invalid (init_buf() wasn't called?).
  local b_guh = vim.b[buf].guh
  assert(b_guh and b_guh.feat and b_guh.bufkey, ('run_term_cmds: invalid b:guh on buf %d'):format(buf))
  local progress = M.new_progress_report('Loading...', buf)
  progress('running')

  if opts and opts.term then
    assert(#cmds == 1, 'run_term_cmds: term=true allows only 1 cmd')
    local env = { GH_PAGER = 'cat', PAGER = 'cat' }
    if vim.g.guh_debug == 'trace' then
      env.GH_DEBUG = 'api'
    end
    vim.schedule(function()
      assert(vim.api.nvim_buf_is_valid(buf), ('run_term_cmds: invalid buf %d'):format(buf))
      -- `jobstart({term=true})` requires the target buf to be curbuf — nvim_buf_call sets that.
      vim.api.nvim_buf_call(buf, function()
        vim.fn.jobstart(cmds[1], {
          term = true,
          env = env,
          on_exit = function()
            if on_done then
              on_done()
            end
            progress('success')
          end,
        })
      end)
    end)
    return
  end

  vim.schedule(function()
    assert(vim.api.nvim_buf_is_valid(buf), ('run_term_cmds: invalid buf %d'):format(buf))

    -- UX: Preserve viewport of windows showing the buf. This makes "reload" less disorienting.
    local winviews = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      winviews[win] = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview()
      end)
    end

    -- (Re)create the terminal-buf channel. `nvim_open_term` can attach to an existing
    -- buftype=terminal if the previous channel is closed.
    local old_chan = (state.get_b_guh(buf) or {}).chan
    if old_chan then
      pcall(vim.fn.chanclose, old_chan)
    end
    local chan = vim.api.nvim_open_term(buf, {})
    -- XXX: store `b:guh.chan` because `nvim_open_term` doesn't set `vim.bo.channel` (Nvim bug).
    state.set_b_guh(buf, { chan = chan })

    local debug = vim.g.guh_debug == 'debug' or vim.g.guh_debug == 'trace'
    local trace = vim.g.guh_debug == 'trace'
    -- Per-cmd result. `exited` is `on_exit` timestamp.
    local r = {} ---@type { out?: string, err?: string, exited?: number }[]
    local start_ms = vim.uv.now()

    local function on_all_done()
      -- Append a timing report.
      local report = { '', '--- timing ---' }
      for i, cmd in ipairs(cmds) do
        local cmd_str = table.concat(cmd, ' '):gsub('%s+', ' ')
        if #cmd_str > 60 then
          cmd_str = cmd_str:sub(1, 57) .. '...'
        end
        table.insert(report, ('%-61s %d ms'):format(cmd_str .. ':', r[i].exited - start_ms))
      end
      vim.api.nvim_chan_send(chan, table.concat(report, '\r\n') .. '\r\n')

      for win, winview in pairs(winviews) do
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_call(win, function()
            vim.fn.winrestview(winview)
          end)
        end
      end
      if on_done then
        on_done()
      end
      progress('success')
    end

    -- Advance through exited cmds, display their output in-order.
    local curr = 1
    local function try_advance()
      while curr <= #cmds and r[curr] and r[curr].exited do
        local out = r[curr].out
        if out and vim.trim(out) ~= '' then
          vim.api.nvim_chan_send(chan, out)
        end
        local err = r[curr].err
        if debug and err and vim.trim(err) ~= '' then
          vim.api.nvim_chan_send(chan, '\r\n--- stderr ---\r\n' .. err)
        end
        curr = curr + 1
      end
      if curr > #cmds then
        on_all_done()
      end
    end

    local pty = opts and opts.pty == true
    local wins = vim.fn.win_findbuf(buf)
    local width = (wins[1] and vim.api.nvim_win_get_width(wins[1])) or 200
    local env = { GH_PAGER = 'cat', PAGER = 'cat' }
    if trace then
      -- `GH_DEBUG=api` logs each HTTP request to stderr with method, URL, status, and round-trip ms.
      env.GH_DEBUG = 'api'
    end
    for i, cmd in ipairs(cmds) do
      local qbuf
      local job_opts = {
        -- Since the cost is server-side (gh API latency), we don't need to "stream" per-command output.
        -- (Except for pty=true, until https://github.com/neovim/neovim/issues/40194 is fixed.)
        stdout_buffered = true,
        stderr_buffered = debug or nil,
        env = env,
        --- @param data string[]
        on_stdout = function(_, data)
          r[i] = r[i] or {}
          r[i].out = (r[i].out or '') .. table.concat(data, '\n')
        end,
        --- @param data string[]
        on_stderr = debug and function(_, data)
          r[i] = r[i] or {}
          r[i].err = table.concat(data, '\n')
        end or nil,
        on_exit = function()
          r[i] = r[i] or {}
          r[i].exited = vim.uv.now()
          if qbuf and vim.api.nvim_buf_is_valid(qbuf) then
            vim.api.nvim_buf_delete(qbuf, { force = true })
          end
          local n_done = 0
          for j = 1, #cmds do
            if r[j] and r[j].exited then
              n_done = n_done + 1
            end
          end
          if n_done < #cmds then
            -- Report progress as cmds complete.
            progress('running', math.floor(100 * n_done / #cmds), '%d/%d', n_done, #cmds)
          end
          try_advance()
        end,
      }

      if pty then
        -- Per-job term=true scratchbuf for handling terminal queries (DA1/OSC/…) from commands like
        -- "gh", which would otherwise hang/timeout waiting for a response. Needed because pty=true
        -- does not handle queries. We also capture raw output via `on_stdout` so we can present the
        -- combined (in-order) results of all jobs in the user-facing buffer.
        qbuf = vim.api.nvim_create_buf(false, true)
        job_opts.term = true
        job_opts.width = width
        vim.api.nvim_buf_call(qbuf, function()
          vim.fn.jobstart(cmd, job_opts)
        end)
      else
        vim.fn.jobstart(cmd, job_opts)
      end
    end
  end)
end

--- Sets the window-local 'winbar' to a list of `{text, hl_group?}` chunks.
---
--- Pass `chunks=nil` to clear/disable.
---
--- @param win integer
--- @param chunks? [string, string?][] List of `{text, hl_group}` pairs, or nil to disable the winbar.
function M.show_winbar(win, chunks)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not chunks then
    vim.wo[win].winbar = ''
    return
  end
  local parts = {}
  for i, ck in ipairs(chunks) do
    local text, hl = ck[1]:gsub('%%', '%%%%'), ck[2] -- escape `%` for statusline syntax
    assert(hl == nil or type(hl) == 'string', 'show_winbar: hl_group must be a string')
    -- Example: ({'foo', 'Comment'}) -> "%#Comment#foo%*"
    table.insert(parts, hl and ('%%#%s#%s%%*'):format(hl, text) or text)
    -- After the first chunk insert `%<` so the title is preserved and truncation (">" marker) cuts from there.
    if i == 1 then
      table.insert(parts, '%<')
    end
  end
  vim.wo[win].winbar = table.concat(parts)
end

return M
