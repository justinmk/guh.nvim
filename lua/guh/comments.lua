local gh = require('guh.gh')
local state = require('guh.state')
local util = require('guh.util')

local M = {}

local severity = vim.diagnostic.severity

local outdated_banner_start = {
  '================================================================================',
  'OUTDATED',
  '',
}
local outdated_banner_end = {
  '================================================================================',
  'END OUTDATED',
  '',
}

--- Builds a self-contained mini-diff for the outdated threads in `comments_list`.
--- Each thread becomes a quasi-file section (`diff --git` + `+++ b/<synthetic>` + hunk) using the
--- synthetic per-thread path the caller stashed on the comment-thread. Example:
---
---     diff --git a/outdated-3271868956:runtime/lua/vim/_core/options.lua b/outdated-3271868956:runtime/lua/vim/_core/options.lua
---     --- a/outdated-3271868956:runtime/lua/vim/_core/options.lua
---     +++ b/outdated-3271868956:runtime/lua/vim/_core/options.lua
---
--- Returns `{}` when nothing is outdated.
---
--- @param comments_list table<string, CommentThread[]>
--- @return string[]
function M.get_outdated_diff(comments_list)
  local entries = {}
  for synthetic, comment_threads in pairs(comments_list) do
    for _, t in ipairs(comment_threads) do
      if assert(t.comments[1]).outdated then
        table.insert(entries, { synthetic = synthetic, thread = t })
      end
    end
  end
  if #entries == 0 then
    return {}
  end
  -- Stable ordering (pairs() is unordered).
  table.sort(entries, function(a, b)
    return a.synthetic < b.synthetic
  end)

  local lines = {}
  vim.list_extend(lines, outdated_banner_start)
  for _, e in ipairs(entries) do
    local first = e.thread.comments[1]
    table.insert(lines, ('diff --git a/%s b/%s'):format(e.synthetic, e.synthetic))
    table.insert(lines, ('--- a/%s'):format(e.synthetic))
    table.insert(lines, ('+++ b/%s'):format(e.synthetic))
    for hunk_line in (first.diff_hunk or ''):gmatch('[^\n]+') do
      table.insert(lines, hunk_line)
    end
  end
  vim.list_extend(lines, outdated_banner_end)
  return lines
end

--- Renders `comments_list` in a 'scrollbind' split next to `diff_win`, with each
--- comment vertically aligned to the diff line it annotates.
---
--- @param id integer PR number.
--- @param repo string "owner/name"
--- @param diff_win integer window of the diff buffer.
--- @param comments_list table<string, CommentThread[]>
--- @param viewed? table<string,boolean> Set of "viewed" files.
--- @param n_files? integer Count of all files in the HEAD diff.
function M.show(id, repo, diff_win, comments_list, viewed, n_files)
  viewed = viewed or {}
  local n_viewed = vim.tbl_count(viewed)
  local diff_buf = vim.api.nvim_win_get_buf(diff_win)
  local diff_lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)

  if not state.try_show('prcomments', repo, id) then
    vim.cmd [[botright vertical split]]
  end
  local buf = state.init_buf('prcomments', repo, id)
  util.set_default_keymaps(buf)

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  -- match window options of diff
  vim.wo.wrap = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.list = false

  ---------------------------------------------------------------------------
  -- Step 1: Parse diff → map each *visible line* to its file + "new" line num
  ---------------------------------------------------------------------------
  local file = nil
  local new_line = 0
  local hunk_start = 0
  local line_map = {} ---@type table<integer, {file:string,new_line:integer|nil}>
  for i, l in ipairs(diff_lines) do
    local plusfile = l:match('^%+%+%+ b/(.+)$')
    if plusfile then
      file = plusfile
      new_line = 0
      hunk_start = 0
    end

    local hunk_new = l:match('^@@ [^+]+%+(%d+)')
    if hunk_new then
      new_line = tonumber(hunk_new)
      hunk_start = i
    elseif file then
      local c = l:sub(1, 1)
      if c == '+' or c == ' ' then
        line_map[i] = { file = file, new_line = new_line }
        new_line = new_line + 1
      elseif c == '-' then
        line_map[i] = { file = file, new_line = nil }
      end
    end
  end

  ---------------------------------------------------------------------------
  -- Step 2: Build text lines for the comment buffer
  ---------------------------------------------------------------------------
  -- entries[i] = { 'line', 'line', … } for diff row i, or nil if nothing anchored there.
  -- Heading lines are prefixed with "▎" so a syntax match can easily highlight them (Step 3).
  local heading_prefix = '▎ '
  local entries = {} ---@type table<integer, string[]>

  local function normalize_diff_path(p)
    p = p:gsub('^b/', '') -- remove Git diff prefix
    p = p:gsub('^a/', '')
    return p
  end

  -- Find the diff-buf line for `gh_line` of `filename`.
  local function find_idx(filename, gh_line)
    if vim.isnil(gh_line) then
      return nil
    end
    for i, m in pairs(line_map) do
      if normalize_diff_path(m.file) == filename and m.new_line == gh_line then
        return i
      end
    end
    return nil
  end

  local diagnostics = {} ---@type vim.Diagnostic[]
  --- Walks the comment threads on a non-"viewed" file. For each thread on visible diff, this function:
  ---   - appends comment lines to `entries[start_idx]` (per-line list of text rows),
  ---   - appends a `diagnostics` entry, scoped to the `[start_idx..end_idx]` range of `diff_buf`.
  ---
  --- Skips "viewed" files.
  ---
  --- @param filename string Key from `comments_list` (may be `outdated-<id>:<path>` format).
  --- @param file_comments CommentThread[]
  local function process_file(filename, file_comments)
    -- Skip "viewed" files. Strip "outdated-<id>:" to match the real path.
    local real_path = filename:match('^outdated%-%d+:(.+)$') or filename
    if viewed[real_path] then
      return
    end
    local normalized_filename = normalize_diff_path(filename)
    for _, thread in ipairs(file_comments) do
      local end_idx = find_idx(normalized_filename, thread.line)
      if end_idx then
        local start_idx = find_idx(normalized_filename, thread.start_line) or end_idx
        if start_idx > end_idx then
          start_idx, end_idx = end_idx, start_idx
        end

        local thread_comments = thread.comments
          or { { user = thread.user, updated_at = thread.updated_at, body = thread.body } }
        local tag = thread_comments[1] and thread_comments[1].outdated and '(outdated) ' or ''

        local thread_entries = entries[start_idx] or {}
        for ci, c in ipairs(thread_comments) do
          local heading = (ci == 1)
              and ('%s%s%s %s %s:%d'):format(
                heading_prefix,
                tag,
                c.user or '?',
                c.updated_at or '',
                filename,
                thread.line
              )
            or ('%s%s %s'):format(heading_prefix, c.user or '?', c.updated_at or '')
          table.insert(thread_entries, heading)
          if c.body and c.body ~= '' then
            for _, bl in ipairs(vim.split(c.body, '\n', { plain = true })) do
              table.insert(thread_entries, bl)
            end
          end
        end
        entries[start_idx] = thread_entries

        local body = table.concat(
          vim.tbl_map(function(c)
            return c.body or ''
          end, thread_comments),
          '\n'
        )
        if body ~= '' then
          table.insert(diagnostics, {
            lnum = start_idx - 1,
            end_lnum = end_idx - 1,
            col = 0,
            message = body,
            severity = severity.INFO,
            source = 'guh.nvim',
          })
        end
      end
    end
  end
  for filename, file_comments in pairs(comments_list) do
    process_file(filename, file_comments)
  end

  local ns = vim.api.nvim_create_namespace('guh.comments')
  vim.diagnostic.set(ns, diff_buf, diagnostics)
  -- This does setqflist(…,"u"), so this won't "pollute" the quickfix list on each refresh.
  vim.diagnostic.setqflist({ namespace = ns, title = 'Guh comments', open = false })

  ---------------------------------------------------------------------------
  -- Step 3: Write to buffer
  ---------------------------------------------------------------------------
  vim.bo[buf].modifiable = true

  -- Each comment starts at its anchored diff line so 'scrollbind' lines up. If a
  -- comment body overflows into the next anchored slot, truncate and mark it so
  -- a sibling comment isn't silently pushed down.
  local anchors = {}
  for i = 1, #diff_lines do
    if entries[i] then
      table.insert(anchors, i)
    end
  end

  local out = {}
  for i = 1, #diff_lines do
    out[i] = ''
  end

  for i, anchor in ipairs(anchors) do
    local thread_entries = entries[anchor]
    local next_anchor = anchors[i + 1] or (#diff_lines + 1)
    local max_lines = math.min(next_anchor - anchor, #diff_lines - anchor + 1)
    if #thread_entries > max_lines then
      thread_entries = vim.list_slice(thread_entries, 1, max_lines)
      thread_entries[max_lines] = (thread_entries[max_lines] or '') .. ' (truncated)'
    end
    for j, line in ipairs(thread_entries) do
      out[anchor + j - 1] = line
    end
  end

  for i = 1, #diff_lines do
    if type(out[i]) ~= 'string' then
      out[i] = ''
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)

  vim.cmd [[wincmd p]] -- Return to diff window.
  local viewed_msg = (n_files and n_files > 0) and (' (%d/%d viewed)'):format(n_viewed, n_files) or ''
  util.show_info_overlay(diff_buf, ('PR diff%s (`g?` for help)'):format(viewed_msg))
  util.show_info_overlay(buf, 'PR comments (`g?` for help)')

  -- vim.bo[buf].modifiable = false
  -- vim.bo[buf].readonly = true
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[syntax match GuhHeading /^▎ \zs.*$/ containedin=ALL]])
    vim.cmd([[syntax match GuhWarning /(outdated)\|(truncated)/ containedin=ALL]])
  end)

  -- Set scrollbind+cursorbind on both windows *after* writing the buffer content.
  vim.api.nvim_win_call(diff_win, function()
    vim.cmd [[setlocal scrollbind cursorbind]]
  end)
  vim.api.nvim_win_call(win, function()
    vim.cmd [[setlocal scrollbind cursorbind]]
  end)
end

--- @param comment Comment
local function format_comment(comment)
  return string.format('✍️ %s at %s:\n%s\n\n', comment.user, comment.updated_at, comment.body)
end

--- Builds a markdown view of all comments associated with a diff-line.
---
--- @param comments Comment[]
local function prepare_content(comments)
  local lines = {}
  if #comments > 0 and not vim.isnil(comments[1].start_line) and comments[1].start_line ~= comments[1].line then
    table.insert(lines, ('📓 Comment on lines %d to %d\n\n'):format(comments[1].start_line, comments[1].line))
  end

  for _, comment in pairs(comments) do
    table.insert(lines, format_comment(comment))
  end

  if #comments > 0 then
    table.insert(lines, ('\n🪓 Diff hunk:\n%s\n'):format(comments[1].diff_hunk))
  end

  return table.concat(lines, '')
end

--- Marshalls an API comment to local `Comment` type.
---
--- @return Comment extracted gh comment
local function convert_comment(comment)
  local extended = vim.tbl_extend('force', {}, comment)
  -- Aliases
  extended.url = comment.html_url
  -- XXX override
  extended.user = comment.user.login
  -- Remove CR chars.
  extended.body = string.gsub(comment.body, '\r', '')
  return extended
end

--- Reshapes the flat list of GitHub review comments into per-file threads. Each `CommentThread` is
--- identified by `in_reply_to_id`.
---
--- @param gh_comments table[] flat list from `gh.get_pr_data`.
--- @param cb fun(comment_threads: table<string, CommentThread[]>)
function M.to_threads(gh_comments, cb)
  --- @type table<number, Comment[]>
  local comment_threads = {}
  local base = {}

  for _, comment in pairs(gh_comments) do
    if comment.in_reply_to_id == nil then
      comment_threads[comment.id] = { convert_comment(comment) }
      base[comment.id] = comment.id
    else
      table.insert(comment_threads[base[comment.in_reply_to_id]], convert_comment(comment))
      base[comment.id] = base[comment.in_reply_to_id]
    end
  end

  --- @type table<string, CommentThread[]>
  local result = {}
  for _, comments in pairs(comment_threads) do
    assert(comments[1])
    --- @type CommentThread
    local comment_thread = {
      id = comments[1].id,
      line = comments[1].line,
      start_line = comments[1].start_line,
      url = comments[#comments].url,
      content = prepare_content(comments),
      comments = comments,
    }

    local filepath = comments[1].path -- Relative file path as given in the unified diff.
    if result[filepath] == nil then
      result[filepath] = { comment_thread }
    else
      table.insert(result[filepath], comment_thread)
    end
  end

  cb(result)
end

M.update_comment = function(opts)
  util.msg('TODO')
end

--- Prepare info for commenting on a range in the current diff.
--- This does not make a network request; it just returns metadata.
---
--- @param line1 integer 1-indexed start line
--- @param line2 integer 1-indexed end line (inclusive)
--- @return table|nil info { buf, pr_id, repo, file, start_line, end_line }
function M.prepare_to_comment(line1, line2)
  local buf = vim.api.nvim_get_current_buf()
  local prnum = assert(vim.b.guh.id)
  local repo = assert(vim.b.guh.repo)
  if not prnum then
    util.msg('Not a PR diff buffer', vim.log.levels.WARN)
    return nil
  end

  line1 = math.max(1, line1)
  line2 = math.max(line1, line2 or line1)
  local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  if vim.tbl_isempty(lines) then
    util.msg('Empty selection', vim.log.levels.WARN)
    return nil
  end

  ---------------------------------------------------------------------------
  -- Step 1: Determine the file path at the start of the selection
  ---------------------------------------------------------------------------
  local file
  for i = line1, 1, -1 do
    local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    local m = l and l:match('^%+%+%+ b/(.+)$')
    if m then
      file = m
      break
    end
  end
  if not file then
    util.msg('Could not determine file from diff', vim.log.levels.WARN)
    return nil
  end
  if file:match('^outdated%-%d+:') then
    util.msg('Cannot comment on an outdated hunk', vim.log.levels.WARN)
    return nil
  end

  ---------------------------------------------------------------------------
  -- Step 2: Validate that the range does not cross into another file section
  ---------------------------------------------------------------------------
  for i = line1, line2 do
    local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if l and l:match('^%+%+%+ b/(.+)$') and not l:match('^%+%+%+ b/' .. vim.pesc(file) .. '$') then
      util.msg('Cannot comment across multiple files in a diff', vim.log.levels.ERROR)
      return nil
    end
  end

  ---------------------------------------------------------------------------
  -- Step 3: Find nearest hunk header (if any)
  ---------------------------------------------------------------------------
  local hunk_start, new_start
  for i = line1, 1, -1 do
    local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    local start_new = l and l:match('^@@ [^+]+%+(%d+)')
    if start_new then
      hunk_start = i
      new_start = tonumber(start_new)
      break
    end
  end

  -- No hunk found → treat as file-level comment
  if not new_start then
    return {
      buf = buf,
      pr_id = tonumber(prnum),
      repo = repo,
      file = file,
      line_start = nil,
      line_end = nil,
    }
  end

  ---------------------------------------------------------------------------
  -- Step 4: Compute new-file line numbers for range
  ---------------------------------------------------------------------------
  local function compute_new_line(idx)
    local line_num = new_start
    for i = hunk_start + 1, idx - 1 do
      local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
      local c = l:sub(1, 1)
      if c ~= '-' then
        line_num = line_num + 1
      end
    end
    return line_num
  end

  local line_start = compute_new_line(line1)
  local line_end = compute_new_line(line2)

  ---------------------------------------------------------------------------
  -- Step 5: Return structured info
  ---------------------------------------------------------------------------
  return {
    buf = buf,
    pr_id = tonumber(prnum),
    repo = repo,
    file = file,
    -- GH expects 0-indexed lines, end-EXclusive.
    start_line = line_start,
    end_line = line_end,
  }
end

--- Posts a file comment on the line at cursor.
---
--- @param line1 integer 1-indexed line
--- @param line2 integer 1-indexed line
function M.do_comment(line1, line2)
  local info = M.prepare_to_comment(line1, line2)
  if not info then
    return
  end

  -- Flash the range so the user can see what they're commenting on.
  vim.hl.range(
    info.buf,
    vim.api.nvim_create_namespace('guh.comment_hl'),
    'Visual',
    { line1 - 1, 0 },
    { line2 - 1, -1 },
    {
      priority = 300, -- Overrule diffs.nvim: https://github.com/barrettruth/diffs.nvim/blob/d280baf3e937a487038766f51156dd41ceb0f8e7/lua/diffs/config.lua#L124-L129
      timeout = 200,
    }
  )

  gh.get_pr_info(info.pr_id, info.repo, function(pr)
    if not pr then
      return util.msg(('PR #%s not found'):format(info.pr_id), vim.log.levels.ERROR)
    end
    vim.schedule(function()
      M.edit_comment('comment', info.pr_id, { '' }, nil, function(input)
        local progress = util.new_progress_report('Sending comment...', vim.api.nvim_get_current_buf())
        gh.new_comment(pr, input, info.file, info.start_line, info.end_line, info.repo, function(resp)
          if resp['errors'] == nil then
            progress('success', nil, 'Comment sent.')
            -- Reload the diff+comments view.
            require('guh.pr').show_pr_diff(info.pr_id)
          else
            progress('failed', nil, 'Failed to send comment.')
          end
        end)
      end)
    end)
  end)
end

--- Opens a markdown buffer prefilled with `content`.
--- - Write-and-save (fugitive-style) confirms the action (invokes `cb`);
--- - Close-without-write or write-empty-buffer aborts the action.
---
--- @param feat 'comment'|'merge'|'review' kind of edit; each has its own per-PR buffer.
--- @param prnum integer
--- @param content string[] lines to prefill the buffer with
--- @param infomsg? { [1]: string, [2]?: string } overlay message + highlight; nil = default.
--- @param cb fun(input: string) called only on save-then-close
function M.edit_comment(feat, prnum, content, infomsg, cb)
  local repo = assert((vim.b.guh or {}).repo, 'edit_comment: not in a guh:// buffer (no b:guh.repo)')
  if not state.try_show(feat, repo, prnum) then
    vim.cmd [[split]]
  end
  local buf = state.init_buf(feat, repo, prnum)
  vim._with({ buf = buf }, function()
    vim.cmd [[set wrap breakindent nonumber norelativenumber nolist]]
  end)

  infomsg = infomsg or { 'Edit, then ZZ to post (ZQ to abort).' }
  util.show_info_overlay(buf, infomsg[1], infomsg[2])

  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe' -- Ensure BufWipeout fires on :q.
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = true
  vim.bo[buf].textwidth = 0

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  -- Stay 'modified' so plain :q is refused: user must pick ZZ (submit) or ZQ (abort).
  vim.bo[buf].modified = true
  vim.cmd [[normal! gg]]

  local group = vim.api.nvim_create_augroup('guh.edit_comment.' .. buf, { clear = true })

  -- Write-and-close confirms the action (vim-fugitive style).
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      local input = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      vim.bo[buf].modified = false
      vim.api.nvim_create_autocmd('BufWipeout', {
        group = group,
        buffer = buf,
        once = true,
        callback = function()
          if vim.trim(input) ~= '' then
            cb(input)
          else
            util.msg('aborted (empty buffer)')
          end
        end,
      })
    end,
  })
end

return M
