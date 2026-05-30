local comments = require('guh.comments')
local config = require('guh.config')
local gh = require('guh.gh')
local state = require('guh.state')
local util = require('guh.util')

local M = {}

--- @param buf integer
local function set_pr_view_keymaps(buf)
  util.buf_keymap(buf, 'n', config.s.keymaps.pr.approve, 'Approve PR', M.approve_pr)
  util.buf_keymap(buf, 'n', config.s.keymaps.pr.request_changes, 'Request PR changes', M.request_changes_pr)
  util.buf_keymap(buf, 'n', config.s.keymaps.pr.merge, 'Merge PR in remote repo', M.merge_pr)
  util.buf_keymap(buf, 'n', config.s.keymaps.pr.comment, 'Comment on PR or diff', M.comment)
  util.buf_keymap(buf, 'x', 'c', 'Comment on PR or diff', M.comment)
  util.buf_keymap(buf, 'n', config.s.keymaps.pr.diff, 'View the PR diff', '<cmd>GuhDiff<cr>')
  util.buf_keymap(buf, 'n', 'ol', 'View the CI logs for this PR', M.show_ci_logs)
end

--- @param buf integer
local function set_issue_view_keymaps(buf)
  util.buf_keymap(buf, 'n', config.s.keymaps.pr.comment, 'Comment on issue', '<cmd>GuhComment<cr>')
end

--- Shows...
--- - Status (if no args given)
--- - PR detail
--- - Issue detail
function M.select(opts)
  local arg = (opts or {}).args or ''
  if 0 == #arg then
    M.show_status()
    return
  end

  local target = util.parse_target(arg)
  if not target then
    util.notify(('Could not parse :Guh argument: %s'):format(arg), vim.log.levels.ERROR)
    return
  end

  local repo_arg = target.owner and (target.owner .. '/' .. target.repo) or nil

  -- URL form already tells us PR vs issue; skip the API probe.
  if target.is_pr ~= nil then
    if target.is_pr then
      M.show_pr(target.id, repo_arg)
    else
      M.show_issue(target.id, repo_arg)
    end
    return
  end

  -- For slug and bare-number forms, probe the API to disambiguate.
  local repo = repo_arg
  if not repo then
    gh.get_repo(function(repo_)
      repo = repo_
    end)
    vim.wait(5000, function()
      return not not repo
    end)
    if not repo then
      util.notify('Failed to get repo info', vim.log.levels.ERROR)
      return
    end
  end

  local test_cmd = vim.system({ 'gh', 'api', ('repos/%s/pulls/%s'):format(repo, target.id) }, { text = true }):wait()
  local is_pr = 0 == test_cmd.code
  if is_pr then
    M.show_pr(target.id, repo_arg)
  else
    M.show_issue(target.id, repo_arg)
  end
end

--- Performs checkout. Shows PR info.
function M.checkout(opts)
  util.notify('TODO')
end

function M.approve_pr()
  util.notify('TODO')
end

function M.request_changes_pr()
  util.notify('TODO')
end

function M.merge_pr()
  util.notify('TODO')
end

function M.load_comments(opts)
  local prnum = opts and opts.args and tonumber(opts.args) or (vim.b.guh or {}).id
  if not prnum then
    util.notify('No PR number provided', vim.log.levels.ERROR)
    return
  end
  comments.load_comments(prnum)
end

function M.show_status()
  local buf = state.init_buf('status', 'all')
  util.run_term_cmd(buf, 'status', 'all', { 'gh', 'status' })
end

--- @param id integer
--- @param repo? string "owner/name", for non-local repo (outside of CWD).
function M.show_issue(id, repo)
  local bufid = repo and (repo .. '/' .. id) or id
  local buf = state.init_buf('issue', bufid, { id = id })
  local cmd = { 'gh', 'issue', 'view', tostring(id) }
  if repo then
    table.insert(cmd, '--repo')
    table.insert(cmd, repo)
  end
  util.run_term_cmd(buf, 'issue', bufid, cmd)
  set_issue_view_keymaps(buf)
end

--- @param id integer
--- @param repo? string "owner/name", for non-local repo (outside of CWD).
function M.show_pr(id, repo)
  local bufid = repo and (repo .. '/' .. id) or id
  local buf = state.init_buf('pr', bufid, { id = id })
  local cmd = { 'gh', 'pr', 'view', '--comments', tostring(id) }
  if repo then
    table.insert(cmd, '--repo')
    table.insert(cmd, repo)
  end
  util.run_term_cmd(buf, 'pr', bufid, cmd, function()
    set_pr_view_keymaps(buf)
  end)
end

function M.show_pr_diff(opts)
  local id = assert(opts and opts.args and tonumber(opts.args) or tonumber(opts) or (vim.b.guh or {}).id)

  local buf = state.init_buf('diff', id)
  util.run_term_cmd(buf, 'diff', id, { 'gh', 'pr', 'diff', tostring(id) }, function()
    M.load_comments()
    vim.cmd [[set filetype=gitcommit]] -- Useful to enable plugins like https://github.com/barrettruth/diffs.nvim
    set_pr_view_keymaps(buf)
  end)
end

--- Comment on a diff line/range, or PR overview (bang "!").
M.comment = function(args)
  assert(args and args.line1 and args.line2)
  if args.bang and args.range then
    return util.notify('Cannot use bang and range together.', vim.log.levels.ERROR)
  end
  if args.bang then
    return util.notify(':GuhComment! (bang) not implemented yet', vim.log.levels.ERROR)
  else
    comments.do_comment(args.line1, args.line2)
  end
end

--- Shows a menu of most-recent CI logs for each (matrix-expanded) job type.
function M.show_ci_logs(opts)
  local id = assert(opts and opts.args and tonumber(opts.args) or tonumber(opts) or (vim.b.guh or {}).id)
  gh.get_pr_info(id, function(pr)
    if not pr then
      return util.notify(('PR #%s not found'):format(id), vim.log.levels.ERROR)
    end
    gh.get_pr_ci_jobs_logs(pr, function(jobs, jobs_err)
      assert(jobs, ('failed to list CI jobs: %s'):format(jobs_err))
      jobs = vim.tbl_filter(function(j) return j.conclusion ~= 'skipped' end, jobs)
      if #jobs == 0 then
        return util.notify(('No (non-skipped) CI jobs for PR #%s'):format(id), vim.log.levels.WARN)
      end

      vim.ui.select(jobs, {
        prompt = ('CI jobs for PR #%s'):format(id),
        format_item = function(j)
          return ('[%s] %s'):format(j.conclusion or j.status or '?', j.name)
        end,
      }, function(picked)
        if not picked then return end
        gh.get_pr_ci_logs(picked.databaseId, function(logs, err)
          assert(logs, ('failed to get CI log: %s'):format(err))

          local buf = state.init_buf('logs', id)
          vim.cmd.buffer(buf)
          vim.bo[buf].buftype = 'nofile'
          vim.bo[buf].bufhidden = 'hide'
          vim.bo[buf].swapfile = false
          vim.bo[buf].modifiable = true
          vim.api.nvim_paste(logs, false, -1)
          vim.bo[buf].modified = false
          vim.bo[buf].modifiable = false
          vim.cmd.norm[[gg0]]
        end)
      end)
    end)
  end)
end

return M
