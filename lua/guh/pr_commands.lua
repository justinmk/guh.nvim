local config = require('guh.config')
local gh = require('guh.gh')
local state = require('guh.state')
local utils = require('guh.utils')

local M = {}

--- @param buf integer
local function set_pr_view_keymaps(buf)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.approve, 'Approve PR', M.approve_pr)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.request_changes, 'Request PR changes', M.request_changes_pr)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.merge, 'Merge PR in remote repo', M.merge_pr)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.comment, 'Comment on PR or diff', M.comment)
  utils.buf_keymap(buf, 'x', 'c', 'Comment on PR or diff', M.comment)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.diff, 'View the PR diff', ':GuhDiff<cr>')
end

--- @param buf integer
local function set_issue_view_keymaps(buf)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.comment, 'Comment on issue', ':GuhComment<cr>')
end

--- Shows...
--- - Status (if no args given)
--- - PR detail
--- - Issue detail
function M.select(opts)
  if 0 == #((opts or {}).args or {}) then
    M.show_status()
    return
  end
  local num = assert(opts and opts.args and tonumber(opts.args))
  local repo
  gh.get_repo(function(repo_)
    repo = repo_
  end)
  vim.wait(5000, function()
    return not not repo
  end)
  if not repo then
    utils.notify('Failed to get repo info', vim.log.levels.ERROR)
    return
  end
  local test_cmd = vim.system({ 'gh', 'api', ('repos/%s/pulls/%s'):format(repo, num) }, { text = true }):wait()
  local is_pr = 0 == (test_cmd).code
  if is_pr and num then
    M.show_pr(num)
  else
    M.show_issue(num)
    -- gh.get_issue(num, show_issue_info)
    -- TODO: issue selection?
  end
end

--- Performs checkout. Shows PR info.
function M.checkout(opts)
  utils.notify('TODO')
end

function M.approve_pr()
  utils.notify('TODO')
end

function M.request_changes_pr()
  utils.notify('TODO')
end

function M.merge_pr()
  utils.notify('TODO')
end

function M.load_comments(opts)
  local prnum = opts.args and tonumber(opts.args) or (vim.b.guh or {}).id
  if not prnum then
    utils.notify('No PR number provided', vim.log.levels.ERROR)
    return
  end
  require('guh.comments').load_comments(prnum)
end

function M.show_status()
  local buf = state.get_buf('status', 'all')
  state.show_buf(buf)
  state.set_b_guh(buf, {
    id = 0,
    feat = 'status',
  })
  utils.run_term_cmd(buf, 'status', 'all', { 'gh', 'status' })
end

--- @param id integer
function M.show_issue(id)
  local buf = state.get_buf('issue', id)
  state.show_buf(buf)
  state.set_b_guh(buf, {
    id = id,
    feat = 'issue',
  })
  utils.run_term_cmd(buf, 'issue', id, { 'gh', 'issue', 'view', tostring(id) })
  set_issue_view_keymaps(buf)
end

function M.show_pr(id)
  local buf = state.get_buf('pr', id)
  state.show_buf(buf)
  state.set_b_guh(buf, {
    id = id,
    feat = 'pr',
  })
  utils.run_term_cmd(buf, 'pr', id, { 'gh', 'pr', 'view', '--comments', tostring(id) })
  set_pr_view_keymaps(buf)
end

function M.show_pr_diff(opts)
  local id = assert(opts and opts.args and tonumber(opts.args) or tonumber(opts) or (vim.b.guh or {}).id)

  local buf = state.get_buf('diff', id)
  state.show_buf(buf)
  state.set_b_guh(buf, {
    id = id,
    feat = 'diff',
  })
  utils.run_term_cmd(buf, 'diff', id, { 'gh', 'pr', 'diff', tostring(id) })
  set_pr_view_keymaps(buf)
end

--- Comment on a PR (bang "!") or a diff line/range.
M.comment = function(args)
  assert(args and args.line1 and args.line2)
  if args.bang and args.range then
    return utils.notify('Cannot use bang and range together.', vim.log.levels.ERROR)
  end
  if args.bang then
    return utils.notify(':GuhComment! (bang) not implemented yet', vim.log.levels.ERROR)
  else
    M.do_comment(args.line1, args.line2)
  end
end

--- Prepare info for commenting on a range in the current diff.
--- This does not make a network request; it just returns metadata.
---
--- @param line1 integer 1-indexed start line
--- @param line2 integer 1-indexed end line (inclusive)
--- @return table|nil info { buf, pr_id, file, start_line, end_line }
function M.prepare_to_comment(line1, line2)
  local buf = vim.api.nvim_get_current_buf()
  local prnum = assert(vim.b.guh.id)
  if not prnum then
    vim.notify('Not a PR diff buffer', vim.log.levels.WARN)
    return nil
  end

  line1 = math.max(1, line1)
  line2 = math.max(line1, line2 or line1)
  local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  if vim.tbl_isempty(lines) then
    vim.notify('Empty selection', vim.log.levels.WARN)
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
    vim.notify('Could not determine file from diff', vim.log.levels.WARN)
    return nil
  end

  ---------------------------------------------------------------------------
  -- Step 2: Validate that the range does not cross into another file section
  ---------------------------------------------------------------------------
  for i = line1, line2 do
    local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if l and l:match('^%+%+%+ b/(.+)$') and not l:match('^%+%+%+ b/' .. vim.pesc(file) .. '$') then
      vim.notify('Cannot comment across multiple files in a diff', vim.log.levels.ERROR)
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

  gh.get_pr_info(info.pr_id, function(pr)
    if not pr then
      return utils.notify(('PR #%s not found'):format(prnum), vim.log.levels.ERROR)
    end
    vim.schedule(function()
      local prompt = '<!-- Type your comment and press ' .. config.s.keymaps.comment.send_comment .. ' to comment: -->'
      utils.edit_comment(info.pr_id, prompt, { prompt, '' }, config.s.keymaps.comment.send_comment, function(input)
        local progress = utils.new_progress_report('Sending comment...', vim.api.nvim_get_current_buf())
        gh.new_comment(pr, input, info.file, info.start_line, info.end_line, function(resp)
          if resp['errors'] == nil then
            progress('success', nil, 'Comment sent.')
            -- TODO this is broken. ignore it for now.
            -- comments.load_comments_on_current_buffer()
          else
            progress('failed', nil, 'Failed to send comment.')
          end
        end)
      end)
    end)
  end)
end

return M
