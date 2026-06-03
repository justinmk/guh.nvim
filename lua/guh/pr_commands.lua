local comments = require('guh.comments')
local gh = require('guh.gh')
local state = require('guh.state')
local util = require('guh.util')

local M = {}

--- Defines buffer-local defaults to the global `<Plug>(guh-…)` mappings, if necessary.
---
--- These defaults are shared across all `guh://*` views (status, PR, issue, diff).
---
--- @param buf integer
local function set_default_keymaps(buf)
  util.map_default(buf, 'n', 'cra', '<Plug>(guh-approve)', 'Approve PR')
  util.map_default(buf, 'n', 'crr', '<Plug>(guh-request-changes)', 'Request PR changes')
  util.map_default(buf, 'n', 'cm', '<Plug>(guh-merge)', 'Merge PR')
  util.map_default(buf, 'n', 'cc', '<Plug>(guh-comment)', 'Comment on PR or diff')
  util.map_default(buf, 'x', 'c', '<Plug>(guh-comment)', 'Comment on PR or diff')
  util.map_default(buf, 'n', 'gd', '<Plug>(guh-diff)', 'View the PR diff')
  util.map_default(buf, 'n', 'gl', '<Plug>(guh-logs)', 'View the CI logs for this PR')
  util.map_default(buf, 'n', 'g?', '<Plug>(guh-help)', 'Show guh-mappings help', { nowait = true })
  util.map_default(buf, 'n', 'R', '<Plug>(guh-refresh)', 'Refresh this guh:// buffer')
end

--- Shows...
--- - Status (if no args given)
--- - PR detail
--- - Issue detail
--- Resolves the current local repo "owner/name", blocking up to 5s.
--- @return string?
local function resolve_local_repo()
  local repo
  gh.get_repo(function(r)
    repo = r
  end)
  vim.wait(5000, function()
    return not not repo
  end)
  return repo
end

function M.select(opts)
  local arg = (opts or {}).args or ''
  if 0 == #arg then
    M.show_status()
    return
  end

  local target = util.parse_target(arg)
  if not target then
    util.msg(('failed to parse: %s'):format(arg), vim.log.levels.ERROR)
    return
  end

  local repo = target.owner and (target.owner .. '/' .. target.repo) or (vim.b.guh or {}).repo or resolve_local_repo()
  if not repo then
    util.msg('Failed to get repo info', vim.log.levels.ERROR)
    return
  end

  -- URL form already tells us PR vs issue; skip the API probe.
  if target.is_pr ~= nil then
    if target.is_pr then
      M.show_pr(target.id, repo)
    else
      M.show_issue(target.id, repo)
    end
    return
  end

  local test_cmd = vim.system({ 'gh', 'api', ('repos/%s/pulls/%s'):format(repo, target.id) }, { text = true }):wait()
  local is_pr = 0 == test_cmd.code
  if is_pr then
    M.show_pr(target.id, repo)
  else
    M.show_issue(target.id, repo)
  end
end

--- Performs checkout. Shows PR info.
function M.checkout(opts)
  util.msg('TODO')
end

function M.approve_pr()
  util.msg('TODO')
end

function M.request_changes_pr()
  util.msg('TODO')
end

--- Refreshes the current `guh://*` buffer by invoking `:Guh <bufname>`.
function M.refresh()
  local feat = (vim.b.guh or {}).feat
  if feat == 'status' then
    return M.show_status()
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name:match('^guh://') then
    -- Drop cached data so the underlying `get_info` re-fetches from gh.
    state.set_b_guh(0, { pr_data = nil, issue_data = nil })
    M.select({ args = name })
  else
    util.msg('Not a guh:// buffer', vim.log.levels.ERROR)
  end
end

--- [count] picks the merge method directly: 1=squash, 2=merge, 3=rebase.
--- No count → vim.ui.select prompt.
function M.merge_pr()
  local id = (vim.b.guh or {}).id
  local repo = (vim.b.guh or {}).repo
  if not id or not repo then
    return util.msg('Not in a PR buffer', vim.log.levels.ERROR)
  end

  local function do_merge(method, subject, body)
    local done = util.progress(('Merging PR #%s (%s)…'):format(id, method))
    gh.merge_pr(id, repo, method, subject, body, function(ok, stderr)
      done(ok and 'success' or 'failed')
      if ok then
        util.msg(('Merged PR #%s'):format(id))
      else
        util.msg(('Merge failed: %s'):format(vim.trim(stderr)), vim.log.levels.ERROR)
      end
    end)
  end

  local function with_method(method)
    if method == 'rebase' then
      return do_merge(method)
    end
    gh.get_pr_info(id, repo, function(pr)
      if not pr then
        return util.msg(('PR #%s not found'):format(id), vim.log.levels.ERROR)
      end
      vim.schedule(function()
        local subject = method == 'merge' and ('Merge #%s %s'):format(id, pr.title) or (pr.title)
        local text = ('%s\n\n%s'):format(subject, pr.body or ''):gsub('\r', '')
        local content = vim.split(text, '\n', { plain = true })
        local infomsg =
          ('[%s] First line = subject; rest = body. ZZ to merge (ZQ to abort).'):format(method)
        comments.edit_comment('merge', id, content, infomsg, function(input)
          local subject, body = input:match('^([^\n]*)\n?(.*)$')
          do_merge(method, subject, vim.trim(body or ''))
        end)
      end)
    end)
  end

  local methods = { 'squash', 'merge', 'rebase' }
  local count = vim.v.count
  if count >= 1 and count <= #methods then
    return with_method(methods[count])
  end

  vim.ui.select(methods, {
    prompt = ('Merge PR #%s by:'):format(id),
  }, function(method)
    if method then
      with_method(method)
    end
  end)
end

function M.load_comments(opts)
  local prnum = opts and opts.args and tonumber(opts.args) or (vim.b.guh or {}).id
  if not prnum then
    util.msg('No PR number provided', vim.log.levels.ERROR)
    return
  end
  local repo = (vim.b.guh or {}).repo or resolve_local_repo()
  comments.load_comments(prnum, repo)
end

function M.show_status()
  local repo = (vim.b.guh or {}).repo or resolve_local_repo()
  local buf = state.init_buf('status', 'all', { repo = repo })
  local cmd = { 'gh', 'status' }
  if repo then
    local owner, name = repo:match('^([^/]+)/(.+)$')
    local query = vim.text.indent(
      0,
      [[
      query($owner:String!,$name:String!){
        repository(owner:$owner,name:$name){
          pullRequests(first:10,states:OPEN,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number title}}
          issues(first:10,states:OPEN,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number title}}
        }
      }
    ]]
    )
    -- "#NNN" matches `b:guh.repo` so <CR> works on these rows.
    local tmpl = vim.text.indent(
      0,
      [[
      {{"\nRecent (open) PRs:\n" -}}
      {{range .data.repository.pullRequests.nodes}}  #{{.number}}  {{.title}}{{"\n"}}{{end -}}
      {{"\nRecent (open) issues:\n" -}}
      {{range .data.repository.issues.nodes}}  #{{.number}}  {{.title}}{{"\n"}}{{end}}
    ]]
    )
    cmd = {
      vim.o.shell,
      vim.o.shellcmdflag,
      ('gh status && gh pr status --repo %s && gh api graphql -f owner=%s -f name=%s -f query=%s --template %s'):format(
        vim.fn.shellescape(repo),
        vim.fn.shellescape(owner),
        vim.fn.shellescape(name),
        vim.fn.shellescape(query),
        vim.fn.shellescape(tmpl)
      ),
    }
  end
  util.run_term_cmd(buf, 'status', 'all', cmd, function()
    set_default_keymaps(buf)
  end)
end

--- @param id integer
--- @param repo string "owner/name"
function M.show_issue(id, repo)
  local bufid = repo .. '/' .. id
  local buf = state.init_buf('issue', bufid, { id = id, repo = repo })
  util.run_term_cmd(buf, 'issue', bufid, gh.cmd(repo, 'issue', 'view', tostring(id)), function()
    set_default_keymaps(buf)
  end)
end

--- @param id integer
--- @param repo string "owner/name"
function M.show_pr(id, repo)
  local bufid = repo .. '/' .. id
  local buf = state.init_buf('pr', bufid, { id = id, repo = repo })
  util.run_term_cmd(buf, 'pr', bufid, gh.cmd(repo, 'pr', 'view', '--comments', tostring(id)), function()
    set_default_keymaps(buf)
  end)
end

function M.show_pr_diff(opts)
  local id = assert(opts and opts.args and tonumber(opts.args) or tonumber(opts) or (vim.b.guh or {}).id)
  local repo = (vim.b.guh or {}).repo or resolve_local_repo()
  local bufid = repo .. '/' .. id
  local buf = state.init_buf('diff', bufid, { id = id, repo = repo })
  util.run_term_cmd(buf, 'diff', bufid, gh.cmd(repo, 'pr', 'diff', tostring(id)), function()
    M.load_comments()
    vim.cmd [[set filetype=gitcommit]] -- Useful to enable plugins like https://github.com/barrettruth/diffs.nvim
    set_default_keymaps(buf)
  end)
end

--- Comment on a diff line/range, or PR overview (bang "!").
M.comment = function(args)
  assert(args and args.line1 and args.line2)
  if args.bang and args.range then
    return util.msg('Cannot use bang and range together.', vim.log.levels.ERROR)
  end
  if args.bang then
    return util.msg(':GuhComment! (bang) not implemented yet', vim.log.levels.ERROR)
  else
    comments.do_comment(args.line1, args.line2)
  end
end

--- Shows a menu of most-recent CI logs for each (matrix-expanded) job type.
function M.show_ci_logs(opts)
  local id = assert(opts and opts.args and tonumber(opts.args) or tonumber(opts) or (vim.b.guh or {}).id)
  local repo = (vim.b.guh or {}).repo or resolve_local_repo()
  gh.get_pr_info(id, repo, function(pr)
    if not pr then
      return util.msg(('PR #%s not found'):format(id), vim.log.levels.ERROR)
    end
    gh.get_pr_ci_jobs_logs(pr, repo, function(jobs, jobs_err)
      assert(jobs, ('failed to list CI jobs: %s'):format(jobs_err))
      jobs = vim.tbl_filter(function(j)
        return j.conclusion ~= 'skipped'
      end, jobs)
      if #jobs == 0 then
        return util.msg(('No (non-skipped) CI jobs for PR #%s'):format(id), vim.log.levels.WARN)
      end

      vim.ui.select(jobs, {
        prompt = ('CI jobs for PR #%s'):format(id),
        format_item = function(j)
          return ('[%s] %s'):format(j.conclusion or j.status or '?', j.name)
        end,
      }, function(picked)
        if not picked then
          return
        end
        gh.get_pr_ci_logs(picked.databaseId, repo, function(logs, err)
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
          vim.cmd.norm [[gg0]]
        end)
      end)
    end)
  end)
end

return M
