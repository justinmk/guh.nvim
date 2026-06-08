--- The main "app" code. Displays PRs/issues/repo-status.

local comments = require('guh.comments')
local gh = require('guh.gh')
local state = require('guh.state')
local util = require('guh.util')

local M = {}

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

--- Finds the first `pr/…` buffer matching the given commit `sha`.
---
--- @param sha string
--- @return integer? pr_id
--- @return integer? commit_idx 1-based index of the matching commit in `pr_data.commits`.
local function find_pr_for_commit_sha(sha)
  for _, pr_buf in pairs(state.bufs.pr or {}) do
    local pr_data = vim.fn.getbufvar(pr_buf, 'guh', {}).pr_data
    for i, c in ipairs(pr_data and pr_data.commits or {}) do
      if c.oid == sha then
        return pr_data.number, i
      end
    end
  end
end

--- Resolves `(pr_id, repo, commit_idx)` from a `:Guh` arg, falling back to `b:guh` and `resolve_local_repo()`.
---
--- If curbuf is "commit/…", searches for the related `pr/…` buf which has that commit.
---
--- @param opts integer|string|table|nil Table form may be cmdline "args", or explicit `{id=…,repo=…}`.
--- @return Feat? feat `b:guh.feat`, or nil if `opts` provided an explicit id.
--- @return integer id
--- @return string repo
--- @return integer? commit_idx Index of the `pr_data.commits` item matching this `commit/…` buf (if applicable).
local function resolve_pr(opts)
  local b_guh = vim.b.guh
  local opts_t = type(opts) == 'table' and opts or {}
  local id = opts_t.id or (opts_t.args and tonumber(opts_t.args)) or tonumber(opts)
  if not id and not b_guh then
    -- UX: `error(…, 0)` skips the "file:line:" prefix.
    error('guh: Not in a guh:// buffer', 0)
  end

  local commit_idx
  if not id then
    -- If we are in a "commit/…" buffer, find the pr with a matching commit.
    if b_guh.feat == 'commit' then
      id, commit_idx = find_pr_for_commit_sha(b_guh.id)
    else
      id = vim._tointeger(b_guh.id)
    end
  end
  if not id then
    error('guh: Failed to resolve PR id', 0)
  end

  local repo = opts_t.repo or (b_guh or {}).repo or resolve_local_repo()
  if not repo then
    error('guh: Failed to resolve repo', 0)
  end
  return b_guh and b_guh.feat or nil, id, repo, commit_idx
end

--- Implements `:Guh`.
---
--- Shows...
--- - Status (if no args given)
--- - PR detail
--- - Issue detail
function M.select(opts)
  if not gh.get_user() then
    util.msg('Not logged in to gh. Run: "gh auth login"', vim.log.levels.ERROR)
    return
  end

  local arg = (opts or {}).args or ''

  -- Flash the cWORD if it matches the arg (so keymaps can use `:Guh <cWORD>` instead of a wrapper).
  if arg == vim.fn.expand('<cWORD>') then
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local s = (line:sub(1, col + 1):match('()%S+$') or col + 2) - 1
    util.hl_flash(0, { row - 1, s }, { row - 1, s + #arg })
  end

  -- Support command mods (`:vertical Guh …`). See `:help <mods>`.
  local smods = (opts or {}).smods or {}
  local window_mod = (smods.split or '') ~= '' or smods.vertical or smods.horizontal or (smods.tab or -1) >= 0
  -- If a command mod was given (`:vertical Guh …`), don't attempt to navigate to an existing window.
  local focus = not window_mod

  -- Resolve target + repo (+ PR/issue probe) BEFORE potential `:new` split, so we can check `b:guh`.
  local target, repo
  if #arg > 0 then
    target = util.parse_target(arg)
    if not target then
      util.msg(('failed to parse: %s'):format(arg), vim.log.levels.ERROR)
      return
    end
    repo = target.owner and (target.owner .. '/' .. target.repo) or (vim.b.guh or {}).repo or resolve_local_repo()
    if not repo then
      util.msg('Failed to get repo info', vim.log.levels.ERROR)
      return
    end
  end

  local function dispatch(is_pr)
    if window_mod then
      vim.cmd(((opts or {}).mods or '') .. ' new')
    end
    if not target then
      M.show_status(focus)
    elseif target.sha then
      M.show_commit(target.sha, repo, focus)
    elseif not target.id then
      -- Repo target ("owner/repo" or "https://github.com/owner/repo" )
      M.show_status(focus, repo)
    elseif target.is_pr == true or (target.is_pr == nil and is_pr) then
      M.show_pr(target.id, repo, focus)
    else
      M.show_issue(target.id, repo, focus)
    end
  end

  if target and target.id and target.is_pr == nil and not target.sha then
    -- Probe PR-vs-issue. Async so the hl_flash() highlight works.
    vim.system({ 'gh', 'api', ('repos/%s/pulls/%s'):format(repo, target.id) }, { text = true }, function(r)
      vim.schedule(function()
        dispatch(r.code == 0)
      end)
    end)
  else
    dispatch(nil)
  end
end

--- Gets commit `sha` from GitHub via `gh api` (no checkout required) and displays it as a `gitcommit` buffer.
---
--- @param sha string Commit SHA (7-40 hex chars).
--- @param repo string "owner/name"
--- @param focus boolean
function M.show_commit(sha, repo, focus)
  local done = util.progress(('Loading commit %s...'):format(sha))
  local cmd = {
    'gh',
    'api',
    ('repos/%s/commits/%s'):format(repo, sha),
    '-H',
    'Accept: application/vnd.github.v3.patch',
  }
  util.system(cmd, function(stdout, stderr, code)
    if code ~= 0 then
      done('failed')
      return util.msg(('Failed to load commit %s: %s'):format(sha, vim.trim(stderr or '')), vim.log.levels.ERROR)
    end
    -- Patch format's first line is "From <full-sha> Mon Sep 17 00:00:00 2001".
    local full_sha = stdout:match('^From%s+(%x+)') or sha
    local buf = state.init_buf('commit', focus, repo, full_sha, { id = full_sha })
    local lines = vim.split(stdout, '\n', { plain = true, trimempty = true })
    util.buf_set_readonly_lines(buf, lines, 'gitcommit')
    util.set_default_keymaps(buf)
    done('success')
  end)
end

--- Navigates to the next/previous PR commit (from latest push), relative to the current `commit/…`
--- buffer (or start/end otherwise).
---
--- @param delta integer # +1 for next, -1 for previous.
function M.show_next_commit(delta)
  local _, id, repo, commit_idx = resolve_pr()
  local pr_buf = assert(state.get_buf('pr', repo, id, false))
  local pr_data = vim.fn.getbufvar(pr_buf, 'guh', {}).pr_data
  local commits = pr_data and pr_data.commits
  if not commits or #commits == 0 then
    error('guh: No commits found; try refresh (R)', 0)
  end
  local idx = commit_idx or (delta > 0 and 0) or (#commits + 1)
  local next_idx = idx + delta
  if next_idx < 1 or next_idx > #commits then
    return util.msg(('No %s commit'):format(delta > 0 and 'next' or 'previous'))
  end
  M.show_commit(commits[next_idx].oid, repo, true)
end

--- Performs the "review PR" action. Shows a vim.ui.select picker unless `[count]` was given.
---
--- Each action opens an editable `guh://<owner>/<repo>/review/<id>` buffer for the (optional) body.
function M.review_pr()
  local _, id, repo = resolve_pr()

  local labels = {
    ['approve'] = { gerund = 'Approving', past = 'Approved' },
    ['comment'] = { gerund = 'Posting review on', past = 'Posted review on' },
    ['request-changes'] = { gerund = 'Requesting changes on', past = 'Requested changes on' },
  }

  local function do_action(action)
    local L = labels[action]
    local msg = ('%s PR #%s. ZZ to submit (ZQ to abort).'):format(L.gerund, id)
    comments.edit_comment('review', id, { '' }, { msg }, function(input)
      local body = vim.trim(input)
      local done = util.progress(('%s PR #%s…'):format(L.gerund, id))
      gh.review_pr(id, repo, action, body, function(ok, stderr)
        done(ok and 'success' or 'failed')
        if ok then
          util.msg(('%s PR #%s'):format(L.past, id))
        else
          util.msg(('Review failed: %s'):format(vim.trim(stderr)), vim.log.levels.ERROR)
        end
      end)
    end)
  end

  local actions = { 'approve', 'request-changes', 'comment' }
  local count = vim.v.count
  if count >= 1 and count <= #actions then
    return do_action(actions[count])
  end

  vim.ui.select(actions, { prompt = ('Review PR #%s by:'):format(id) }, function(action)
    if action then
      do_action(action)
    end
  end)
end

--- Refreshes the current `guh://*` buffer by invoking `:Guh <bufname>`.
function M.refresh()
  local feat = util.require_b_guh({ 'feat' })
  if not feat then
    return
  end
  if feat == 'status' then
    return M.show_status(true)
  end
  -- Drop cached pr_data on the `/pr/…` buf so `gh.get_pr_data` doesn't use stale data.
  local b = vim.b.guh or {}
  if b.repo and b.id then
    local pr_buf = state.get_buf('pr', b.repo, b.id, false)
    if pr_buf then
      state.set_b_guh(pr_buf, { pr_data = nil })
    end
  end
  M.select({ args = vim.api.nvim_buf_get_name(0) })
end

--- Performs the "merge PR" action. Shows a vim.ui.select picker unless `[count]` was given.
function M.merge_pr()
  local _, id, repo = resolve_pr()

  local function do_merge(choice, subject, body)
    local method = choice:match('^(%S+)')
    local admin = choice:find('--admin', 1, true) ~= nil
    local done = util.progress(('Merging PR #%s (%s)…'):format(id, choice))
    gh.merge_pr(id, repo, method, subject, body, admin, function(ok, stderr)
      done(ok and 'success' or 'failed')
      if ok then
        util.msg(('Merged PR #%s'):format(id))
      else
        util.msg(('Merge failed: %s'):format(vim.trim(stderr)), vim.log.levels.ERROR)
      end
    end)
  end

  local function with_choice(choice)
    local method = choice:match('^(%S+)')
    local admin = choice:find('--admin', 1, true) ~= nil
    if method == 'rebase' then
      return do_merge(choice)
    end
    gh.get_pr_data(id, repo, nil, function(pr)
      if not pr then
        return util.msg(('PR #%s not found'):format(id), vim.log.levels.ERROR)
      end
      vim.schedule(function()
        local subject, body
        if method == 'merge' then
          subject = ('Merge #%s %s'):format(id, pr.title)
          body = pr.body or ''
        elseif method == 'squash' then -- Prefill body with commit messages instead of PR desc.
          subject = ('%s #%s'):format(pr.title, id)
          local cs = pr.commits or {}
          if #cs == 1 and vim.trim(cs[1].messageHeadline) == vim.trim(pr.title) then
            -- Single commit: don't append redundant subject line, just use the commit body (like GitHub web).
            body = cs[1].messageBody
          else
            local parts = {}
            for _, c in ipairs(cs) do
              local entry = ('* %s'):format(c.messageHeadline)
              if c.messageBody ~= '' then
                entry = entry .. '\n\n' .. c.messageBody
              end
              table.insert(parts, entry)
            end
            body = table.concat(parts, '\n\n')
          end
        else
          error(('unknown method: %s'):format(method))
        end
        local text = ('%s\n\n%s'):format(subject, body):gsub('\r', '')
        local content = vim.split(text, '\n', { plain = true })
        local msg = ('[%s] First line = subject; rest = body. ZZ to merge (ZQ to abort).'):format(choice)
        comments.edit_comment('merge', id, content, { msg, admin and 'DiagnosticError' }, function(input)
          local subject, body = input:match('^([^\n]*)\n?(.*)$')
          do_merge(choice, subject, vim.trim(body or ''))
        end)
      end)
    end)
  end

  local choices = { 'squash', 'merge', 'rebase', 'squash --admin', 'merge --admin', 'rebase --admin' }
  local count = vim.v.count
  if count >= 1 and count <= #choices then
    return with_choice(choices[count])
  end

  vim.ui.select(choices, { prompt = ('Merge PR #%s by:'):format(id) }, function(choice)
    if choice then
      with_choice(choice)
    end
  end)
end

--- @param focus boolean
--- @param repo? string Optional "owner/name" repo.
function M.show_status(focus, repo)
  repo = repo or (vim.b.guh or {}).repo or resolve_local_repo()
  local buf = state.init_buf('status', focus, nil, 'all', { repo = repo })
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
      {{"\nOpen PRs (recently updated):\n" -}}
      {{range .data.repository.pullRequests.nodes}}  #{{.number}}  {{.title}}{{"\n"}}{{end -}}
      {{"\nOpen issues (recently updated):\n" -}}
      {{range .data.repository.issues.nodes}}  #{{.number}}  {{.title}}{{"\n"}}{{end}}
    ]]
    )
    cmd = util.shell_cmd(
      'gh status && gh pr status --repo %s && gh api graphql -f owner=%s -f name=%s -f query=%s --template %s',
      repo,
      owner,
      name,
      query,
      tmpl
    )
  end
  util.run_term_cmd(buf, cmd, function()
    util.set_default_keymaps(buf)
  end)
end

--- @param id integer
--- @param repo string "owner/name"
--- @param focus boolean
function M.show_issue(id, repo, focus)
  local buf = state.init_buf('issue', focus, repo, id)
  util.run_term_cmd(buf, gh.cmd(repo, 'issue', 'view', tostring(id), '--comments'), function()
    util.set_default_keymaps(buf)
  end)
end

--- Shows PR details + the most-recent commits (since the last force-push).
---
--- Loads the prdiff/ + prcomments/ buffers also.
---
--- @param id integer
--- @param repo string "owner/name"
--- @param focus boolean
function M.show_pr(id, repo, focus)
  local buf = state.init_buf('pr', focus, repo, id)
  -- `oid` is the full SHA; slice the first 7 chars. `committedDate` is ISO-8601.
  local commits_tmpl = vim.text.indent(
    0,
    [[
    {{printf "\nCommits (%d):\n" (len .commits) -}}
    {{range .commits}}  {{slice .oid 0 12}}  {{slice .committedDate 0 10}}  {{.messageHeadline}}{{"\n"}}{{end}}
  ]]
  )
  local cmd = util.shell_cmd(
    'gh pr view --comments %s --repo %s && gh pr view %s --repo %s --json commits --template %s',
    id,
    repo,
    id,
    repo,
    commits_tmpl
  )

  util.run_term_cmd(buf, cmd, function()
    util.set_default_keymaps(buf)
  end)

  -- Load prdiff/ + prcomments/. The pr/ buf (init_buf above) becomes the alt-buf of prdiff/.
  -- Deferred via `vim.schedule` so it runs AFTER `run_term_cmd`'s own scheduled
  -- `state.show_buf(pr_buf)`, so we can focus prdiff/ as curbuf.
  vim.schedule(function()
    M.show_pr_diff({ id = id, repo = repo })
  end)
end

--- Shows PR diff + comments.
--- - Outdated-unresolved diff + comments are shown at top.
--- - Current diff + comments are shown after that.
--- - "Viewed" files collapse to a `(viewed) <path>` line.
--- - Diff + comments are presented as 2 'scrollbind' windows.
function M.show_pr_diff(opts)
  local _, id, repo = resolve_pr(opts)
  local buf = state.init_buf('prdiff', true, repo, id)
  local diff_win = vim.api.nvim_get_current_win()

  local progress = util.new_progress_report('Loading PR diff...', buf)
  progress('running')

  local pr_data --[[@type PullRequest?]]
  local diff_stdout
  local function try_render()
    if not pr_data or not diff_stdout then
      return
    end
    local lines, threads, n_files, n_viewed_threads = comments.render_diff(pr_data, diff_stdout)
    util.log(('comment threads (total: %s)'):format(vim.tbl_count(threads)), threads)
    -- filetype=gitcommit enables plugins like https://github.com/barrettruth/diffs.nvim
    util.buf_set_readonly_lines(buf, lines, 'gitcommit')
    vim.api.nvim_buf_call(buf, function()
      vim.cmd([[syntax match GuhWarning /^(viewed)/ containedin=ALL]])
      -- Match offdiff file prefix ("outdated-3271868956:", "outside-3271868956:").
      vim.cmd([[syntax match GuhWarning /\<\(outdated\|outside\)\ze-\d\+:/ containedin=ALL]])
    end)
    util.set_default_keymaps(buf)
    comments.show(
      id,
      repo,
      diff_win,
      threads,
      pr_data.viewed,
      n_files,
      pr_data.n_threads,
      pr_data.n_resolved,
      n_viewed_threads
    )
    progress('success')
  end

  -- 1. Fetch PR data (force API request, skip cache).
  gh.get_pr_data(id, repo, { force = true }, function(pr)
    if not pr then
      return progress('failed')
    end
    pr_data = pr
    try_render()
  end)

  -- 2. Get the current PR diff.
  util.system(gh.cmd(repo, 'pr', 'diff', tostring(id)), function(stdout, stderr, code)
    if code ~= 0 then
      progress('failed', nil, vim.trim(stderr or ''))
      return
    end
    diff_stdout = stdout
    try_render()
  end)
end

--- Comment on a diff line/range, or PR/issue overview (bang "!").
---
--- In a `prcomments/…` buffer (instead of `prdiff/…`): updates the existing comment at cursor.
M.comment = function(args)
  assert(args and args.line1 and args.line2)
  if args.bang and (args.range or 0) > 0 then
    return util.msg('Cannot use bang and range together.', vim.log.levels.ERROR)
  end
  if args.bang then
    return M.comment_overview()
  end
  if (vim.b.guh or {}).feat == 'prcomments' then
    return comments.update_comment(args.line1)
  end
  comments.do_comment(args.line1, args.line2)
end

--- Posts a top-level comment on the current PR or issue.
function M.comment_overview()
  local feat, id, repo = resolve_pr()
  local kind = feat == 'issue' and 'issue' or 'pr'

  comments.edit_comment('comment', id, { '' }, nil, function(input)
    local progress = util.new_progress_report('Sending comment...', vim.api.nvim_get_current_buf())
    gh.new_overview_comment(kind, id, repo, input, function(ok, stderr)
      if ok then
        progress('success', nil, 'Comment sent.')
      else
        progress('failed', nil, ('Failed to send comment: %s'):format(vim.trim(stderr or '')))
      end
    end)
  end)
end

--- Runs `gh pr edit <id>` (or `gh issue edit <id>`) in a :terminal.
function M.edit_pr()
  local feat, id, repo = resolve_pr()
  local kind = feat == 'issue' and 'issue' or 'pr'
  local buf = state.init_buf('edit', true, repo, id)
  util.run_term_cmd(buf, gh.cmd(repo, kind, 'edit', tostring(id)), function()
    util.set_default_keymaps(buf)
  end)
end

--- Shows a menu of most-recent CI logs for each (matrix-expanded) job type.
function M.show_ci_logs(opts)
  local _, id, repo = resolve_pr(opts)
  gh.get_pr_data(id, repo, nil, function(pr)
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

          local buf = state.init_buf('logs', true, repo, id)
          vim.cmd.buffer(buf)
          -- Logs from `gh run view --log` contain termcodes. Open the buffer as a terminal so it renders nicely.
          local chan = vim.api.nvim_open_term(0, {})
          vim.api.nvim_chan_send(chan, logs)
          vim.cmd.norm [[gg0]]
        end)
      end)
    end)
  end)
end

return M
