--- Handles PR comments and PR diff processing (mapping comments to diff lines).

local gh = require('guh.gh')
local state = require('guh.state')
local util = require('guh.util')

local M = {}

local severity = vim.diagnostic.severity
local diag_ns = vim.api.nvim_create_namespace('guh.comments')
local comment_hl_ns = vim.api.nvim_create_namespace('guh.comment_hl')

--- Filename prefixes for threads that anchor outside the visible HEAD diff. They get
--- rewritten by `pr.show_pr_diff` so each becomes a own quasi-file entry; the mini-diff below
--- uses the comment's `diff_hunk` as the body.
---
--- - `outdated-<thread_id>:` : Thread is on a stale push (`PullRequestReviewThread.isOutdated`).
--- - `outside-<thread_id>:` : Thread is on HEAD, but outside the PR diff.
local outdated_prefix_pat = '^outdated%-%d+:'
local outside_prefix_pat = '^outside%-%d+:'

-- Flashes a text region so the user can see what an action
local function flash_region(buf, line1, line2)
  vim.hl.range(buf, comment_hl_ns, 'Visual', { line1 - 1, 0 }, { line2 - 1, -1 }, {
    priority = 300, -- Overrule diffs.nvim: https://github.com/barrettruth/diffs.nvim/blob/d280baf3e937a487038766f51156dd41ceb0f8e7/lua/diffs/config.lua#L124-L129
    timeout = 200,
  })
end

--- Builds a self-contained mini-diff for threads matching `file_prefix`. Each thread becomes
--- a quasi-file section (`diff --git` + `index` + `+++ b/<filepath>` + hunk) using the quasi-file
--- prefix. Example for "outdated":
---
---     diff --git a/outdated-3271868956:runtime/lua/vim/_core/options.lua b/outdated-3271868956:runtime/lua/vim/_core/options.lua
---     index 0000000..0000000 100644
---     --- a/outdated-3271868956:runtime/lua/vim/_core/options.lua
---     +++ b/outdated-3271868956:runtime/lua/vim/_core/options.lua
---
--- Returns `{}` when nothing matches.
---
--- @param comments_list table<string, CommentThread[]>
--- @param file_prefix string
--- @return string[]
local function to_offdiff_section(comments_list, file_prefix)
  local entries = {}
  for synthetic, comment_threads in pairs(comments_list) do
    if synthetic:match('^' .. file_prefix .. '%-%d+:') then
      for _, t in ipairs(comment_threads) do
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
  for _, e in ipairs(entries) do
    local first = e.thread.comments[1]
    table.insert(lines, ('diff --git a/%s b/%s'):format(e.synthetic, e.synthetic))
    -- Fake "index" line for visual symmetry with real diff sections (dummy SHA).
    table.insert(lines, 'index 0000000..0000000 100644')
    table.insert(lines, ('--- a/%s'):format(e.synthetic))
    table.insert(lines, ('+++ b/%s'):format(e.synthetic))
    for hunk_line in (first.diff_hunk or ''):gmatch('[^\n]+') do
      table.insert(lines, hunk_line)
    end
  end
  return lines
end

--- Maps each diff-buffer row to its `{file, old_line, new_line}` tuple. Only
--- body rows ("+", "-", " ") get an entry; file/hunk/blank rows are nil.
---
--- - "+" row: only `new_line` set (added, RIGHT side).
--- - "-" row: only `old_line` set (deleted, LEFT side).
--- - " " row: both set (context).
---
--- @param diff_lines string[]
--- @return table<integer, {file:string, new_line:integer|nil, old_line:integer|nil}>
local function to_line_map(diff_lines)
  local file = nil
  local new_line = 0
  local old_line = 0
  local line_map = {}
  for i, l in ipairs(diff_lines) do
    local plusfile = l:match('^%+%+%+ b/(.+)$')
    if plusfile then
      file = plusfile
      new_line = 0
      old_line = 0
    end
    local hunk_old, hunk_new = l:match('^@@ %-(%d+),?%d* %+(%d+)')
    if hunk_new then
      old_line = tonumber(hunk_old)
      new_line = tonumber(hunk_new)
    elseif file then
      local c = l:sub(1, 1)
      if c == '+' then
        line_map[i] = { file = file, new_line = new_line, old_line = nil }
        new_line = new_line + 1
      elseif c == '-' then
        line_map[i] = { file = file, new_line = nil, old_line = old_line }
        old_line = old_line + 1
      elseif c == ' ' then
        line_map[i] = { file = file, new_line = new_line, old_line = old_line }
        new_line = new_line + 1
        old_line = old_line + 1
      end
    end
  end
  return line_map
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
  -- Step 1: Parse diff → map each *visible line* to its file + new/old line num
  ---------------------------------------------------------------------------
  local line_map = to_line_map(diff_lines)

  ---------------------------------------------------------------------------
  -- Step 2: Build text lines for the comment buffer
  ---------------------------------------------------------------------------
  -- entries[i] = list of {heading, body} blocks for diff row i, or nil if
  -- nothing anchored there. Tracking heading + body separately lets Step 3
  -- guarantee every comment's heading row when multiple threads pile up on
  -- the same diff line.
  -- Heading lines are prefixed so a syntax match can easily highlight them (Step 3).
  local heading_prefix = '▎ '
  local entries = {} ---@type table<integer, { heading: string, body: string[] }[]>

  local function normalize_diff_path(p)
    p = p:gsub('^b/', '') -- remove Git diff prefix
    p = p:gsub('^a/', '')
    return p
  end

  -- Find the diff-buf line for `gh_line` of `filename`. `side` selects the
  -- axis: 'LEFT' = old-file (deleted/context), anything else = new-file.
  local function find_idx(filename, gh_line, side)
    if vim.isnil(gh_line) then
      return nil
    end
    local axis = (side == 'LEFT') and 'old_line' or 'new_line'
    for i, m in pairs(line_map) do
      if normalize_diff_path(m.file) == filename and m[axis] == gh_line then
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
    -- Skip "viewed" files. Strip "outdated-<id>:" and "outside-<id>:" to match the real path.
    local real_path = (filename:gsub(outdated_prefix_pat, ''):gsub(outside_prefix_pat, ''))
    if viewed[real_path] then
      return
    end
    local normalized_filename = normalize_diff_path(filename)
    for _, thread in ipairs(file_comments) do
      -- The thread's head comment sets the side; replies inherit. Comments
      -- with side='LEFT' anchor to deleted/old-file lines.
      local side = thread.comments[1] and thread.comments[1].side
      local end_idx = find_idx(normalized_filename, thread.line, side)
      if end_idx then
        local start_idx = find_idx(normalized_filename, thread.start_line, side) or end_idx
        if start_idx > end_idx then
          start_idx, end_idx = end_idx, start_idx
        end

        local thread_comments = thread.comments
          or { { user = thread.user, updated_at = thread.updated_at, body = thread.body } }
        local tag = thread_comments[1] and thread_comments[1].outdated and '(outdated) ' or ''

        local comment_blocks = entries[start_idx] or {}
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
          local body = {}
          if c.body and c.body ~= '' then
            for _, bl in ipairs(vim.split(c.body, '\n', { plain = true })) do
              table.insert(body, bl)
            end
          end
          table.insert(comment_blocks, { heading = heading, body = body })
        end
        entries[start_idx] = comment_blocks

        -- One diagnostic per-thread. The `Comment[]` list is stored in `user_data.comments`,
        -- so `update_comment` can pick from it.
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
            user_data = { comments = thread_comments },
          })
        end
      end
    end
  end
  for filename, file_comments in pairs(comments_list) do
    process_file(filename, file_comments)
  end

  vim.diagnostic.set(diag_ns, diff_buf, diagnostics)
  -- This does setqflist(…,"u"), so this won't "pollute" the quickfix list on each refresh.
  vim.diagnostic.setqflist({ namespace = diag_ns, title = 'Guh comments', open = false })

  ---------------------------------------------------------------------------
  -- Step 3: Write comment threads to buffer
  ---------------------------------------------------------------------------
  vim.bo[buf].modifiable = true

  -- Each comment starts at its anchored diff line so 'scrollbind' aligns. If a
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
    local comment_blocks = entries[anchor]
    local next_anchor = anchors[i + 1] or (#diff_lines + 1)
    local max_lines = math.min(next_anchor - anchor, #diff_lines - anchor + 1)
    local n_comments = #comment_blocks

    -- Render: each comment is guaranteed its heading row; bodies fill the remaining vertical space.
    -- So a big comment can't starve the headings of sibling comments anchored to the same diff line.
    local rendered = {}
    local truncated = false
    if n_comments > max_lines then
      -- Even one row per comment overflows; show as many headings as fit.
      for j = 1, max_lines do
        table.insert(rendered, comment_blocks[j].heading)
      end
      truncated = true
    else
      local body_budget = max_lines - n_comments
      for _, blk in ipairs(comment_blocks) do
        table.insert(rendered, blk.heading)
        for _, bl in ipairs(blk.body) do
          if body_budget > 0 then
            table.insert(rendered, bl)
            body_budget = body_budget - 1
          else
            truncated = true
            break
          end
        end
      end
    end
    if truncated and #rendered > 0 then
      rendered[#rendered] = rendered[#rendered] .. ' (truncated)'
    end
    for j, line in ipairs(rendered) do
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
    vim.cmd([[syntax match GuhWarning /(outdated)\|(outside)\|(truncated)/ containedin=ALL]])
  end)

  -- Set scrollbind+cursorbind on both windows *after* writing the buffer content.
  vim.api.nvim_win_call(diff_win, function()
    vim.cmd [[setlocal scrollbind cursorbind]]
    vim.cmd [[keepjumps syncbind]]
  end)
  vim.api.nvim_win_call(win, function()
    vim.cmd [[setlocal scrollbind cursorbind]]
  end)
end

--- Marshalls an API comment to local `Comment` type.
---
--- @return Comment extracted gh comment
local function to_comment(comment)
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
      comment_threads[comment.id] = { to_comment(comment) }
      base[comment.id] = comment.id
    else
      table.insert(comment_threads[base[comment.in_reply_to_id]], to_comment(comment))
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

--- Prepares the output of `gh pr diff` for display.
---
--- - Replaces "viewed" files with a single `(viewed) <path>` line
--- - Counts files in the diff
---
--- @param difftext string Raw `gh pr diff` output.
--- @param viewed table<string,boolean> Map of "viewed" files.
--- @return string[] lines, integer n_files
local function prepare_pr_diff(difftext, viewed)
  local out, total = {}, 0
  local skipping = false
  for line in vim.gsplit(difftext, '\n', { plain = true, trimempty = true }) do
    local path = line:match('^diff %-%-git a/(.-) b/')
    if path then
      total = total + 1
      if viewed[path] then
        table.insert(out, ('(viewed) %s'):format(path))
        skipping = true
      else
        table.insert(out, line)
        skipping = false
      end
    elseif not skipping then
      table.insert(out, line)
    end
  end
  return out, total
end

--- Returns true if comment `c` anchors to a visible line in `line_map`, comparing (file, axis-line)
--- where axis depends on `c.side`.
---
--- @param line_map table<integer, {file:string, new_line:integer|nil, old_line:integer|nil}>
--- @param c Comment
local function in_diff(line_map, c)
  if vim.isnil(c.line) then
    return false
  end
  local axis = c.side == 'LEFT' and 'old_line' or 'new_line'
  for _, m in pairs(line_map) do
    if m.file == c.path and m[axis] == c.line then
      return true
    end
  end
  return false
end

--- Renders `gh pr diff <id>` stdout for presentation in a "prdiff/…" buffer:
---
--- Rewrite diff-hunk filenames to `<kind>-<thread_id>:<path>` quasi-filename for:
---   - "outdated" threads (anchored to stale code, GraphQL: `isOutdated`).
---     (Example: "outdated-3271868956:runtime/lua/vim/_core/options.lua")
---   - "outside" threads (anchored outside of the PR diff).
---   - Collapses VIEWED files.
---   - Groups comments into per-file threads (`to_threads`).
---
--- @param raw_comments Comment[]   Flat per-comment list from `gh.get_pr_data`. Mutated in-place to rewrite paths.
--- @param viewed table<string,boolean>
--- @param diff_stdout string  Raw `gh pr diff` output.
--- @param cb fun(lines: string[], threads: table<string,CommentThread[]>, n_files: integer)
function M.render_diff(raw_comments, viewed, diff_stdout, cb)
  local diff_lines, n_files = prepare_pr_diff(diff_stdout, viewed)
  local line_map = to_line_map(diff_lines)
  for _, c in ipairs(raw_comments) do
    if c.thread_id then
      if c.outdated then
        c.path = ('outdated-%d:%s'):format(c.thread_id, c.path)
      elseif not viewed[c.path] and not in_diff(line_map, c) then
        -- Viewed files are collapsed, so not in `line_map`.
        -- But their comments are still on the PR, don't move them to "outside".
        c.path = ('outside-%d:%s'):format(c.thread_id, c.path)
      end
    end
  end
  M.to_threads(raw_comments, function(threads)
    local lines = vim
      .iter({
        to_offdiff_section(threads, 'outdated'),
        to_offdiff_section(threads, 'outside'),
        diff_lines,
      })
      :flatten()
      :totable()
    cb(lines, threads, n_files)
  end)
end

--- Finds the comment(s) at or above `linenr` by walking up to the nearest diagnostic (from the
--- "prdiff/…" buffer). Emits a warning if no comments found.
---
--- @param linenr integer 1-indexed line number.
--- @return integer? prnum
--- @return string? repo
--- @return { comment: Comment, range: { integer, integer } }[]? candidates
local function comments_at_line(linenr)
  local prnum, repo = util.require_b_guh({ 'id', 'repo' })
  if not prnum then
    return
  end

  local diff_buf = state.get_buf('prdiff', repo, prnum, true)
  if not diff_buf then
    util.msg('No prdiff buffer for this PR', vim.log.levels.WARN)
    return
  end

  -- Walk upward from cursor until to find the nearest diagnostic. Lets the action work anywhere
  -- in a comment's rendered region. Skip if cursor is on a blank line ("not a comment").
  local ds = {}
  if vim.fn.getline(linenr) ~= '' then
    for row = linenr, 1, -1 do
      ds = vim.diagnostic.get(diff_buf, { lnum = row - 1, namespace = diag_ns })
      if #ds > 0 then
        break
      end
    end
  end

  -- One diagnostic per thread; flatten to candidates. `range` carries the thread's diff-range so
  -- the action can highlight it with `vim.hl.range`.
  local candidates = {}
  for _, d in ipairs(ds) do
    for _, c in ipairs(d.user_data.comments or {}) do
      table.insert(candidates, { comment = c, range = { d.lnum, d.end_lnum } })
    end
  end

  if #candidates == 0 then
    util.msg('No comment at cursor', vim.log.levels.WARN)
    return
  end

  return prnum, repo, candidates
end

--- Auto-picks the candidate (if exactly one) or shows a `vim.ui.select` picker.
local function pick_comment(comments, prompt, on_pick)
  if #comments == 1 then
    return on_pick(comments[1])
  end
  vim.ui.select(comments, {
    prompt = prompt,
    format_item = function(cand)
      local c = cand.comment
      local snippet = (c.body or ''):gsub('\n.*$', ''):sub(1, 60)
      return ('%s %s: %s'):format(c.user or '?', c.updated_at or '', snippet)
    end,
  }, function(cand)
    if cand then
      on_pick(cand)
    end
  end)
end

--- Updates the comment near `linenr`, in a `prcomments/…` buffer. Identifies the comment by querying the
--- sibling `prdiff/…` buffer's per-comment diagnostics.
---
--- - When multiple comments share a diff row, prompts via `vim.ui.select`.
--- - Flashes the comment region.
--- - Opens a prefilled `edit_comment` buffer.
--- - Posts on write-and-close.
---
--- @param linenr integer 1-indexed cursor row in the prcomments buffer.
function M.update_comment(linenr)
  local buf = vim.api.nvim_get_current_buf()
  local prnum, repo, candidates = comments_at_line(linenr)
  if not prnum then
    return
  end

  local function do_it(cand)
    local c = cand.comment
    flash_region(buf, cand.range[1] + 1, cand.range[2] + 1)
    local content = vim.split(c.body or '', '\n', { plain = true })
    M.edit_comment(
      'comment',
      prnum,
      content,
      { ('Updating comment %d. ZZ to confirm (ZQ to abort).'):format(c.id) },
      function(input)
        local progress = util.new_progress_report('Updating comment...', vim.api.nvim_get_current_buf())
        gh.update_comment(c.id, input, repo, function(resp)
          if resp['errors'] == nil then
            progress('success', nil, 'Comment updated.')
            require('guh.pr').show_pr_diff(prnum) -- Refresh.
          else
            progress('failed', nil, 'Failed to update comment.')
          end
        end)
      end
    )
  end

  pick_comment(candidates, 'Which comment?', do_it)
end

--- Acts on a comment thread (Reply or Resolve).
---
--- @param linenr integer 1-indexed line number.
function M.reply_or_resolve(linenr)
  local buf = vim.api.nvim_get_current_buf()
  local prnum, repo, candidates = comments_at_line(linenr)
  if not prnum then
    return
  end

  local function do_it(cand)
    local c = cand.comment
    flash_region(buf, cand.range[1] + 1, cand.range[2] + 1)

    vim.ui.select({ 'Reply', 'Resolve' }, {
      prompt = ('Thread on %s:%d:'):format(c.path or '?', c.line or 0),
    }, function(action)
      if action == 'Reply' then
        M.edit_comment(
          'comment',
          prnum,
          { '' },
          { ('Reply to %s. ZZ to send (ZQ to abort).'):format(c.user or '?') },
          function(input)
            local progress = util.new_progress_report('Sending reply...', vim.api.nvim_get_current_buf())
            gh.reply_to_comment(prnum, input, c.id, repo, function(resp)
              if resp['errors'] == nil then
                progress('success', nil, 'Reply sent.')
                require('guh.pr').show_pr_diff(prnum) -- Refresh.
              else
                progress('failed', nil, 'Failed to send reply.')
              end
            end)
          end
        )
      elseif action == 'Resolve' then
        if not c.thread_node_id then
          return util.msg('Missing thread_node_id (refresh and retry)', vim.log.levels.WARN)
        end
        local progress = util.new_progress_report('Resolving thread...', buf)
        gh.resolve_thread(c.thread_node_id, function(resp)
          if resp['errors'] == nil then
            progress('success', nil, 'Thread resolved.')
            require('guh.pr').show_pr_diff(prnum) -- Refresh.
          else
            progress('failed', nil, 'Failed to resolve thread.')
          end
        end)
      end
    end)
  end

  pick_comment(candidates, 'Which comment?', do_it)
end

--- Prepare info for commenting on a range in the current diff.
--- This does not make a network request; it just returns metadata.
---
--- @param line1 integer 1-indexed start line
--- @param line2 integer 1-indexed end line (inclusive)
--- @return table|nil info { buf, pr_id, repo, file, side, start_line, end_line }
function M.prepare_to_comment(line1, line2)
  local buf = vim.api.nvim_get_current_buf()
  local prnum = assert(vim.b.guh.id)
  local repo = assert(vim.b.guh.repo)

  line1 = math.max(1, line1)
  line2 = math.max(line1, line2 or line1)

  local line_map = to_line_map(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local start_entry = line_map[line1]
  local end_entry = line_map[line2]
  if not start_entry or not end_entry then
    util.msg('Not a diff line (file/hunk header or blank?)', vim.log.levels.WARN)
    return nil
  end
  if start_entry.file:match(outdated_prefix_pat) or start_entry.file:match(outside_prefix_pat) then
    util.msg('Cannot comment on an outdated/outside hunk', vim.log.levels.WARN)
    return nil
  end

  -- LEFT-side ('-') rows have no new_line; RIGHT-side ('+'/' ') rows do.
  local side = start_entry.new_line == nil and 'LEFT' or 'RIGHT'

  -- Validate range. Non-body rows (hunk/file headers, blanks) have no entry
  -- and are skipped — only actual diff rows constrain the range.
  for i = line1, line2 do
    local e = line_map[i]
    if e then
      if e.file ~= start_entry.file then
        util.msg('Cannot comment across multiple files in a diff', vim.log.levels.ERROR)
        return nil
      end
      local e_side = e.new_line == nil and 'LEFT' or 'RIGHT'
      if e_side ~= side then
        util.msg('Cannot comment across both sides of the diff', vim.log.levels.ERROR)
        return nil
      end
    end
  end

  local axis = side == 'LEFT' and 'old_line' or 'new_line'
  return {
    buf = buf,
    pr_id = tonumber(prnum),
    repo = repo,
    file = start_entry.file,
    side = side,
    start_line = start_entry[axis],
    end_line = end_entry[axis],
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

  flash_region(info.buf, line1, line2)

  gh.get_pr_data(info.pr_id, info.repo, nil, function(pr)
    if not pr then
      return util.msg(('PR #%s not found'):format(info.pr_id), vim.log.levels.ERROR)
    end
    vim.schedule(function()
      M.edit_comment('comment', info.pr_id, { '' }, nil, function(input)
        local progress = util.new_progress_report('Sending comment...', vim.api.nvim_get_current_buf())
        gh.new_comment(pr, input, info.file, info.start_line, info.end_line, info.side, info.repo, function(resp)
          if resp['errors'] == nil then
            progress('success', nil, 'Comment sent.')
            require('guh.pr').show_pr_diff(info.pr_id) -- Refresh.
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
