--- Handles PR comments and PR diff processing (mapping comments to diff lines).

local gh = require('guh.gh')
local state = require('guh.state')
local util = require('guh.util')

local M = {}

local severity = vim.diagnostic.severity
local diag_ns = vim.api.nvim_create_namespace('guh.comments')

--- Filename prefixes for threads that anchor outside the visible HEAD diff. They get
--- rewritten by `M.render_diff` so each becomes a own quasi-file entry; the mini-diff below
--- uses the comment's `diff_hunk` as the body.
---
--- - `outdated-<thread_id>:` : Thread is on a stale push (`PullRequestReviewThread.isOutdated`).
--- - `outside-<thread_id>:` : Thread is on HEAD, but outside the PR diff.
local outdated_prefix_pat = '^outdated%-%d+:'
local outside_prefix_pat = '^outside%-%d+:'

-- Returns the 1-indexed inclusive [line1, line2] of the rendered comment block at cursor.
local function find_block()
  local line1 = vim.fn.search([[^▎]], 'bcnW')
  if line1 == 0 then
    return nil
  end
  local blank = vim.fn.search([[^$]], 'nW')
  return { line1, blank == 0 and vim.fn.line('$') or blank - 1 }
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

--- Display path: opens prcomments/ in a 'scrollbind' split next to the prdiff window, and sets
--- winbar + scrollbind on both. Assumes `load_pr_comments` has already populated the buf.
---
--- @param id integer PR number.
--- @param repo string "owner/name"
--- @param diff_buf integer prdiff buffer.
--- @param pr_data PullRequest
--- @param n_files integer
--- @param n_viewed_threads integer
function M.show_pr_comments(id, repo, diff_buf, pr_data, n_files, n_viewed_threads)
  if not state.try_show('prcomments', repo, id) then
    -- TODO: should state.init_buf() handle this? maybe helpful for <mods> handling on :Guh too?
    vim.cmd [[botright vertical split]]
  end
  local buf = state.init_buf('prcomments', true, repo, id) -- focus=true
  util.set_default_keymaps(buf)
  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
  vim.cmd [[set wrap breakindent nonumber norelativenumber nolist]]

  local visible_threads = pr_data.n_threads - pr_data.n_resolved - n_viewed_threads
  local n_viewed = vim.tbl_count(pr_data.viewed or {})
  vim.cmd [[wincmd p]] -- Return to diff window.
  local diff_win = vim.fn.win_findbuf(diff_buf)[1]
  local comments_win = vim.fn.win_findbuf(buf)[1]
  util.show_winbar(diff_win, {
    { 'PR diff | ', 'Comment' },
    { ('Files: %d ('):format(n_files, n_viewed), 'Comment' },
    { 'Viewed', '@markup.italic' },
    { (': %d) | '):format(n_viewed), 'Comment' },
    { 'Unresolved', '@markup.italic' },
    { (' threads: %d'):format(visible_threads), 'Comment' },
    { ' | g? for help', 'Comment' },
  })
  util.show_winbar(comments_win, {
    { ('PR comments | Visible: %d | Unresolved in '):format(visible_threads), 'Comment' },
    { 'Viewed', '@markup.italic' },
    { (' files: %d'):format(n_viewed_threads), 'Comment' },
    { ' | g? for help', 'Comment' },
  })

  -- Set scrollbind+cursorbind on both windows *after* writing the buffer content.
  vim.api.nvim_win_call(diff_win, function()
    vim.cmd [[setlocal scrollbind cursorbind]]
    vim.cmd [[keepjumps syncbind]]
  end)
  vim.api.nvim_win_call(comments_win, function()
    vim.cmd [[setlocal scrollbind cursorbind]]
  end)
end

--- Renders `comments_list` into the `prcomments/…` buffer, with each comment vertically aligned to
--- the diff line it annotates. Sets diagnostics on `diff_buf`. Does NOT display the buffer.
---
--- @param id integer PR number.
--- @param repo string "owner/name"
--- @param diff_buf integer prdiff buffer (provides the diff text + receives diagnostics).
--- @param pr_data PullRequest (provides `viewed`, `n_threads`, `n_resolved`).
--- @param comments_list table<string, CommentThread[]>
--- @param n_files integer Count of all files in the HEAD diff.
--- @param n_viewed_threads integer Unresolved threads hidden in "Viewed" files.
--- @return integer buf the prcomments buffer.
function M.load_pr_comments(id, repo, diff_buf, pr_data, comments_list, n_files, n_viewed_threads)
  local viewed = pr_data.viewed or {}
  local diff_lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)

  local buf = state.init_buf('prcomments', nil, repo, id)

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
    if gh_line == nil then
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
  ---   - sets start_bufline/end_bufline on each Comment.
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
      local end_idx = find_idx(normalized_filename, thread.end_line, side)
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
                thread.end_line
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
          -- XXX: Store the rendered buf-line range on each Comment.
          for _, c in ipairs(thread_comments) do
            c.start_bufline = start_idx
            c.end_bufline = end_idx
          end
          table.insert(diagnostics, {
            lnum = start_idx - 1,
            end_lnum = end_idx,
            col = 0,
            end_col = 0,
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

  -- vim.bo[buf].modifiable = false
  -- vim.bo[buf].readonly = true
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[syntax match GuhHeading /^▎ \zs.*$/ containedin=ALL]])
    vim.cmd([[syntax match GuhWarning /(outdated)\|(outside)\|(truncated)/ containedin=ALL]])
  end)

  return buf
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
--- @return table<string, CommentThread[]>
function M.to_threads(gh_comments)
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
      end_line = comments[1].end_line,
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

  return result
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
  if c.end_line == nil then
    return false
  end
  local axis = c.side == 'LEFT' and 'old_line' or 'new_line'
  for _, m in pairs(line_map) do
    if m.file == c.path and m[axis] == c.end_line then
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
--- @param pr_data PullRequest Note: `raw_comments` is mutated in-place to rewrite paths.
--- @param diff_stdout string  Raw `gh pr diff` output.
--- @return string[] lines
--- @return table<string,CommentThread[]> threads
--- @return integer n_files
--- @return integer n_viewed_threads Unresolved threads in "viewed" files.
function M.render_diff(pr_data, diff_stdout)
  local viewed = pr_data.viewed
  local diff_lines, n_files = prepare_pr_diff(diff_stdout, viewed)
  local line_map = to_line_map(diff_lines)
  local viewed_threads = {} ---@type table<integer, true>
  for _, c in ipairs(pr_data.raw_comments) do
    if viewed[c.path] and c.thread_id then
      viewed_threads[c.thread_id] = true
    end
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
  local threads = M.to_threads(pr_data.raw_comments)
  local lines = vim
    .iter({
      to_offdiff_section(threads, 'outdated'),
      to_offdiff_section(threads, 'outside'),
      diff_lines,
    })
    :flatten()
    :totable()
  return lines, threads, n_files, vim.tbl_count(viewed_threads)
end

--- Finds the comment(s) at or above `linenr` by walking up to the nearest diagnostic (from the
--- "prdiff/…" buffer). Emits a warning if no comments found.
---
--- @param linenr integer 1-indexed line number.
--- @return integer? prnum
--- @return string? repo
--- @return Comment[]? candidates
local function comments_at_line(linenr)
  local prnum, repo = util.require_b_guh({ 'id', 'repo' })
  if not prnum then
    return
  end

  local diff_buf = state.get_buf('prdiff', repo, prnum, false)
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

  -- One diagnostic per thread; flatten to candidates.
  local candidates = {}
  for _, d in ipairs(ds) do
    for _, c in ipairs(d.user_data.comments or {}) do
      table.insert(candidates, c)
    end
  end

  if #candidates == 0 then
    util.msg('No comment at cursor', vim.log.levels.WARN)
    return
  end

  return prnum, repo, candidates
end

--- Auto-picks the candidate (if exactly one) or shows a `vim.ui.select` picker.
---
---@param on_pick fun(choice: Comment)
local function pick_comment(comments, prompt, on_pick)
  if #comments == 1 then
    return on_pick(comments[1])
  end
  vim.ui.select(comments, {
    prompt = prompt,
    format_item = function(c)
      local snippet = (c.body or ''):gsub('\n.*$', ''):sub(1, 60)
      return ('%s %s: %s'):format(c.user or '?', c.updated_at or '', snippet)
    end,
  }, function(c)
    if c then
      on_pick(c)
    end
  end)
end

--- Performs an action on a comment at `linenr`. Identifies the comment by querying the sibling
--- `prdiff/…` buffer's per-comment diagnostics.
---
--- - When multiple comments share a diff row, prompts via `vim.ui.select`.
--- - Flashes the comment region.
---
--- @param linenr integer 1-indexed line number
--- @param prompt string Picker prompt text (only if there are multiple candidates).
--- @param on_comment fun(c: Comment, prnum: integer, repo: string, buf: integer): nil
--- @param filter? fun(c: Comment[]): Comment[] Optional candidate filter (e.g. dedupe by thread).
local function with_comment(linenr, prompt, on_comment, filter)
  local buf = vim.api.nvim_get_current_buf()
  local prnum, repo, candidates = comments_at_line(linenr)
  if not prnum then
    return
  end
  if filter then
    candidates = filter(candidates)
  end
  local block = find_block()
  pick_comment(candidates, prompt, function(c)
    local r = block or { c.start_bufline, c.end_bufline }
    util.hl_flash(buf, r[1] - 1, r[2] - 1)
    on_comment(c, prnum, assert(repo), buf)
  end)
end

--- Deletes the PR review comment at `linenr`. Prompts for confirmation.
---
--- @param linenr integer 1-indexed line number in the prdiff/prcomments buffer.
function M.delete_comment(linenr)
  with_comment(linenr, 'Delete which comment?', function(c, prnum, repo, buf)
    local prompt = ('Delete comment by %s? %q'):format(c.user or '?', (c.body or ''):gsub('\n.*$', ''):sub(1, 60))
    if vim.fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
      return
    end
    local progress = util.new_progress_report('Deleting comment...', buf)
    gh.delete_comment(c.id, repo, function(resp)
      if not resp or resp.errors == nil then
        progress('success', nil, 'Comment deleted.')
        require('guh.pr').refresh({ feat = 'pr', id = prnum, repo = repo })
      else
        progress('failed', nil, 'Failed to delete comment.')
      end
    end)
  end)
end

--- Updates the comment near `linenr`, in a `prcomments/…` buffer.
---
--- - Opens a prefilled `edit_comment` buffer.
--- - Posts on write-and-close.
---
--- @param linenr integer 1-indexed cursor row in the prcomments buffer.
function M.update_comment(linenr)
  with_comment(linenr, 'Which comment?', function(c, prnum, repo, _)
    local content = vim.split(c.body or '', '\n', { plain = true })
    local same = gh.get_user() == c.user
    local infomsg = same and { { ('Updating comment %d | ZZ to confirm (ZQ to abort)'):format(c.id), 'Comment' } }
      or {
        { 'Updating comment by ', 'Comment' },
        { ('%s %d (not you)'):format(c.user or '?', c.id), 'ErrorMsg' },
        { ' | ZZ to confirm (ZQ to abort)', 'Comment' },
      }
    M.edit_comment('comment', prnum, content, infomsg, function(input)
      local progress = util.new_progress_report('Updating comment...', vim.api.nvim_get_current_buf())
      gh.update_comment(c.id, input, repo, function(resp)
        if resp['errors'] == nil then
          progress('success', nil, 'Comment updated.')
          require('guh.pr').refresh({ feat = 'pr', id = prnum, repo = repo })
        else
          progress('failed', nil, 'Failed to update comment.')
        end
      end)
    end)
  end)
end

--- Acts on a comment thread (Reply or Resolve).
---
--- @param linenr integer 1-indexed line number.
function M.reply_or_resolve(linenr)
  -- Reply/Resolve is a _thread_ action: dedupe so the user isn't prompted for "Which comment?".
  local function dedupe_threads(candidates)
    return vim
      .iter(candidates)
      :unique(function(c)
        return c.thread_id
      end)
      :totable()
  end
  with_comment(linenr, 'Which comment thread?', function(c, prnum, repo, buf)
    vim.ui.select({ 'Reply', 'Resolve' }, {
      prompt = ('Thread on %s:%d:'):format(c.path or '?', c.end_line or 0),
    }, function(action)
      if action == 'Reply' then
        M.edit_comment(
          'comment',
          prnum,
          { '' },
          { { ('Reply to %s. ZZ to send (ZQ to abort)'):format(c.user or '?'), 'Comment' } },
          function(input)
            local progress = util.new_progress_report('Sending reply...', vim.api.nvim_get_current_buf())
            gh.reply_to_comment(prnum, input, c.id, repo, function(resp)
              if resp['errors'] == nil then
                progress('success', nil, 'Reply sent.')
                require('guh.pr').refresh({ feat = 'pr', id = prnum, repo = repo })
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
            require('guh.pr').refresh({ feat = 'pr', id = prnum, repo = repo })
          else
            progress('failed', nil, 'Failed to resolve thread.')
          end
        end)
      end
    end)
  end, dedupe_threads)
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

--- Posts a file comment on the diff-line at cursor.
---
--- @param line1 integer 1-indexed line
--- @param line2 integer 1-indexed line
function M.new_comment(line1, line2)
  local info = M.prepare_to_comment(line1, line2)
  if not info then
    return
  end

  util.hl_flash(info.buf, line1 - 1, line2 - 1)

  gh.get_pr_data(info.pr_id, info.repo, nil, function(pr)
    if not pr then
      return util.msg(('PR #%s not found'):format(info.pr_id), vim.log.levels.ERROR)
    end
    local range = info.start_line == info.end_line and tostring(info.end_line)
      or ('%d..%d'):format(info.start_line, info.end_line)
    local infomsg = {
      { 'Comment on ', 'Comment' },
      { ('%s:%s'):format(info.file, range), 'Directory' },
      { ' | ZZ to send (ZQ to abort)', 'Comment' },
    }
    vim.schedule(function()
      M.edit_comment('comment', info.pr_id, { '' }, infomsg, function(input)
        local progress = util.new_progress_report('Sending comment...', vim.api.nvim_get_current_buf())
        gh.new_comment(pr, input, info.file, info.start_line, info.end_line, info.side, info.repo, function(resp)
          if resp['errors'] == nil then
            progress('success', nil, 'Comment sent.')
            require('guh.pr').refresh({ feat = 'pr', id = info.pr_id, repo = info.repo })
          else
            progress('failed', nil, 'Failed to send comment.')
          end
        end)
      end)
    end)
  end)
end

--- Opens a markdown buffer prefilled with `content`.
--- - Write-and-close (fugitive-style) confirms the action (invokes `on_confirm`);
--- - Close-without-write or write-empty-buffer aborts the action (shows a message, skips `on_confirm`).
---
--- @param feat 'comment'|'merge'|'review' kind of edit; each has its own per-PR buffer.
--- @param prnum integer
--- @param content string[] lines to prefill the buffer with
--- @param infomsg? [string, string?][] Heading text + highlights; nil = default.
--- @param on_confirm fun(input: string) Called on write-and-close (not on abort/cancel).
function M.edit_comment(feat, prnum, content, infomsg, on_confirm)
  local repo = assert((vim.b.guh or {}).repo, 'edit_comment: not in a guh:// buffer (no b:guh.repo)')
  if not state.try_show(feat, repo, prnum) then
    vim.cmd [[split]]
  end
  local buf = state.init_buf(feat, true, repo, prnum)
  vim._with({ buf = buf }, function()
    vim.cmd [[set wrap breakindent nonumber norelativenumber nolist]]
  end)

  util.show_winbar(0, infomsg or { { 'Edit comment | ZZ to post (ZQ to abort)', 'Comment' } })

  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe' -- Ensure BufWipeout fires on :q.
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = true
  vim.bo[buf].textwidth = 0

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  -- Stay 'modified' so plain :q is refused: user must pick ZZ (submit) or ZQ (abort).
  vim.bo[buf].modified = true
  vim.cmd [[normal! gg]]

  -- Write-and-close confirms the action (vim-fugitive style).
  -- Defer via vim.schedule so `on_confirm` runs after the "close" step (and the edit window is gone).
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    once = true,
    callback = function()
      local input = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      vim.bo[buf].modified = false
      vim.schedule(function()
        if vim.trim(input) ~= '' then
          on_confirm(input)
        else
          util.msg('aborted (empty buffer)')
        end
      end)
    end,
  })
  -- Close-without-write (ZQ) leaves `modified=true`; ZZ-confirm sets `modified=false` above.
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      if vim.bo[buf].modified then
        util.msg('aborted')
      end
    end,
  })
end

return M
