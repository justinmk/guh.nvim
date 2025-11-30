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
  util.buf_keymap(buf, 'n', 'cL', 'View the CI logs for this PR', M.show_ci_logs)
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
    util.notify('Failed to get repo info', vim.log.levels.ERROR)
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
function M.show_issue(id)
  local buf = state.init_buf('issue', id)
  util.run_term_cmd(buf, 'issue', id, { 'gh', 'issue', 'view', tostring(id) })
  set_issue_view_keymaps(buf)
end

function M.show_pr(id)
  local buf = state.init_buf('pr', id)
  util.run_term_cmd(buf, 'pr', id, { 'gh', 'pr', 'view', '--comments', tostring(id) })
  set_pr_view_keymaps(buf)
end

function M.show_pr_diff(opts)
  local id = assert(opts and opts.args and tonumber(opts.args) or tonumber(opts) or (vim.b.guh or {}).id)

  local buf = state.init_buf('diff', id)
  util.run_term_cmd(buf, 'diff', id, { 'gh', 'pr', 'diff', tostring(id) }, function()
    M.load_comments()
  end)
  set_pr_view_keymaps(buf)
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

function M.show_ci_logs(opts)
  local id = assert(opts and opts.args and tonumber(opts.args) or tonumber(opts) or (vim.b.guh or {}).id)
  gh.get_pr_info(id, function(pr)
    if not pr then
      return util.notify(('PR #%s not found'):format(id), vim.log.levels.ERROR)
    end
    gh.get_pr_ci_logs(pr, function(logs)
      local buf = state.init_buf('logs', id)
      vim.cmd.buffer(buf)
      assert(logs, 'failed to get CI logs')
      vim.api.nvim_paste(logs, false, -1)
    end)
  end)
end

-- Show fuzzy picker.
function M.select_pr_job(opts)
  local id = assert(opts and opts.args and tonumber(opts.args) or tonumber(opts) or (vim.b.guh or {}).id)
  gh.get_pr_info(id, function(pr)
    if not pr then
      return util.notify(('PR #%s not found'):format(id), vim.log.levels.ERROR)
    end
    gh.get_pr_jobs(pr, function(jobs, err)
      if err then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end

      -- Extract just the job names
      local job_names = vim.tbl_map(function(job)
        return job.name .. ' (' .. job.status .. ')'
      end, jobs)

      require('fzf-lua').fzf_exec(job_names, {
        prompt = 'Jobs> ',
        actions = {
          ['default'] = function(selected)
            vim.notify('Selected: ' .. selected[1])
          end,
        },
      })
    end)
  end)
end

return M
