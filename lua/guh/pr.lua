--- The main "app" code. Displays PRs/issues/repo-status.

local comments = require('guh.comments')
local gh = require('guh.gh')
local state = require('guh.state')
local util = require('guh.util')

local M = {}

--- Resolves the repo "owner/name" for the current buffer, may block up to 5s.
--- 1. checks `b:guh.repo`.
--- 2. else, locates .git/ relative to curbuf.
--- 3. else, locates .git/ relative to getcwd().
---
--- @return string?
local function resolve_repo()
  local b_guh = vim.b.guh
  if b_guh and b_guh.repo then
    return b_guh.repo
  end
  local bufname = vim.api.nvim_buf_get_name(0)
  local is_uri = bufname:match('^%w+://')
  local dir = (bufname ~= '' and not is_uri) and vim.fs.dirname(bufname) or vim.fn.getcwd()

  local repo
  gh.get_repo(dir, function(r)
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
--- @return integer? commit_idx 1-based index of the matching `pr_data.commits` item.
local function find_pr_for_commit_sha(sha)
  for _, pr_buf in pairs(state.bufs.pr or {}) do
    local pr_data = state.get_pr_data(pr_buf)
    for i, c in ipairs(pr_data and pr_data.commits or {}) do
      if c.oid == sha then
        return pr_data.number, i
      end
    end
  end
end

--- Resolves `(pr_id, repo, commit_idx)` from a `:Guh` arg, falling back to `b:guh` and `resolve_repo()`.
---
--- If curbuf is "commit/…", searches for the related `pr/…` buf which has that commit.
---
--- @param opts integer|string|table|nil Table form may be cmdline "args", or explicit `{id=…,repo=…}`.
--- @param optional? boolean (default: true) return nil instead of raising "Not a PR" error.
--- @return Feat? feat `b:guh.feat`, or nil if `opts` provided an explicit id.
--- @return integer id
--- @return string repo
--- @return integer? commit_idx Index of the `pr_data.commits` item matching this `commit/…` buf (if applicable).
local function resolve_pr(opts, optional)
  optional = optional or optional == nil
  local b_guh = vim.b.guh
  local opts_t = type(opts) == 'table' and opts or {}
  local id = opts_t.id or (opts_t.args and tonumber(opts_t.args)) or tonumber(opts)
  if not id and not b_guh then
    -- UX: `error(…, 0)` skips the "file:line:" prefix.
    error('guh: Not in a guh:// buffer', 0)
  end
  -- Reject non-PR bufs early. Note: guh://status has `id=0`.
  if not optional and not id and b_guh and (b_guh.feat == 'issue' or b_guh.feat == 'status') then
    error('guh: Not a PR', 0)
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

  local repo = opts_t.repo or resolve_repo()
  if not repo then
    error('guh: Failed to resolve repo', 0)
  end
  return b_guh and b_guh.feat or nil, id, repo, commit_idx
end

--- @param opts? integer|string|table
local function require_pr(opts)
  return resolve_pr(opts, false)
end

--- Implements `:Guh`. Also provides an overload for programmatic callers.
---
--- Shows...
--- - Status (if no args given)
--- - PR detail
--- - Issue detail
---
--- @param args vim.api.keyset.create_user_command.command_args
--- @overload fun(feat: Feat, id?: integer|string, repo?: string)
function M.select(args, id, repo)
  if not gh.get_user() then
    util.msg('Not logged in to gh. Run: "gh auth login"', vim.log.levels.ERROR)
    return
  end

  -- Overloads:
  -- - cmdargs for :Guh.
  -- - `{feat, id, repo}` for programmatic callers.
  local cmdargs = type(args) == 'table' and args or {}
  local feat = type(args) == 'string' and args or nil
  local arg = cmdargs.args or ''

  -- `:Guh .` reads cWORD.
  -- Flash the cWORD (bonus: also for `:Guh <cWORD>`).
  if arg == '.' or arg == vim.fn.expand('<cWORD>') then
    arg = vim.fn.expand('<cWORD>')
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local on_blank = vim.api.nvim_get_current_line():sub(col + 1, col + 1):match('%S') == nil
    local _, c = unpack(vim.fn.searchpos([[\v(^|\s)@<=\S]], on_blank and 'cnW' or 'bcnW'))
    util.hl_flash(0, { row - 1, c - 1 }, { row - 1, c - 1 + #arg })
  end

  -- Support command mods (`:vertical Guh …`). See `:help <mods>`.
  local smods = cmdargs.smods or {}
  local window_mod = (smods.split or '') ~= '' or smods.vertical or smods.horizontal or (smods.tab or -1) >= 0
  -- If a command mod was given (`:vertical Guh …`), don't attempt to navigate to an existing window.
  local focus = not window_mod

  -- Resolve target + repo (+ PR/issue probe) BEFORE potential `:new` split, so we can check `b:guh`.
  local target --[[@type table?]]
  if feat then
    -- Programmatic caller provided (feat, id, repo) directly. Skip parsing.
    target = {
      id = id,
      is_pr = ({ pr = true, prdiff = true, prcomments = true, prlogs = true, issue = false })[feat],
    }
    repo = repo or resolve_repo()
  elseif #arg > 0 then
    target = util.parse_target(arg)
    if not target then
      util.msg(('failed to parse: %s'):format(arg), vim.log.levels.ERROR)
      return
    end
    repo = target.owner and (target.owner .. '/' .. target.repo) or resolve_repo()
    if not repo then
      util.msg('Failed to get repo info', vim.log.levels.ERROR)
      return
    end
  end

  local function dispatch(is_pr)
    if window_mod then
      vim.cmd((cmdargs.mods or '') .. ' new')
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
    -- Optimization: skip the probe (API request) if the key is already stored locally.
    if state.get_buf('pr', repo, target.id, false) then
      dispatch(true)
    elseif state.get_buf('issue', repo, target.id, false) then
      dispatch(false)
    else -- Probe PR-vs-issue. Async so the hl_flash() highlight works.
      vim.system({ 'gh', 'api', ('repos/%s/pulls/%s'):format(repo, target.id) }, { text = true }, function(r)
        vim.schedule(function()
          dispatch(r.code == 0)
        end)
      end)
    end
  else
    dispatch(nil)
  end
end

--- Gets commit `sha` from GitHub via `gh api` (no checkout required) and displays it as a `gitcommit` buffer.
---
--- No "refresh": commits are immutable, so each `commit/<sha>` buf never needs a "refresh".
---
--- @param sha string Commit SHA (7-40 hex chars).
--- @param repo string "owner/name"
--- @param focus boolean
function M.show_commit(sha, repo, focus)
  -- Optimization: If the `commit/<sha>` buf already exits, just navigate to it.
  local existing = state.get_buf('commit', repo, sha, false)
  if existing and vim.api.nvim_buf_line_count(existing) > 1 then
    state.init_buf('commit', focus, repo, sha, { id = sha }) -- Show the buffer.
    return
  end
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

--- Renders `logs` into a `prlogs/…` terminal-buf, or does nothing if `b:guh.chan` is already set.
local function render_ci_log(buf, logs)
  if (state.get_b_guh(buf) or {}).chan then
    -- To "refresh" a prlogs/ buffer: chanclose() + 'modifiable' + clear.
    -- But this is only for reference, since we never "refresh" prlogs/ buffers.
    -- pcall(vim.fn.chanclose, old_chan)
    -- vim.bo[buf].modifiable = true
    -- vim.bo[buf].readonly = false
    -- vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    return
  end
  local chan = vim.api.nvim_open_term(buf, {})
  vim.api.nvim_chan_send(chan, logs)
  -- state.set_b_guh(buf, { chan = chan })
  vim.fn.chanclose(chan)
  util.set_default_keymaps(buf)
  if vim.api.nvim_get_current_buf() == buf then
    vim.cmd.norm [[gg0]]
  end
end

--- Shows a `prlogs/…` buffer. Fetches the logs unless `b:guh.chan` is set (= already rendered).
---
--- No "refresh": `databaseId` is unique per-run (we don't currently support in-progress logs), so
--- each `prlogs/<databaseId>` buf never needs a "refresh".
---
--- @param job CIJob From `pr_data.ci_jobs`.
--- @param pr_id integer
--- @param repo string "owner/name"
local function show_ci_log(job, pr_id, repo)
  -- Key the bufname by `job.databaseId` to disambiguate (multiple logs per PR).
  -- XXX: store pr-id in `b:guh.id` for refresh/actions.
  local buf = state.init_buf('prlogs', true, repo, job.databaseId, { id = pr_id })
  local status = job.conclusion or job.status or '?'
  util.show_winbar(0, {
    { ('Logs | PR #%s | '):format(pr_id), 'Comment' },
    { status == 'success' and '✅' or '❌' },
    { (' "%s"'):format(job.name), 'Comment' },
  })
  if (state.get_b_guh(buf) or {}).chan then
    return -- Cache hit (preload or prior open).
  end
  gh.get_pr_ci_log(job.databaseId, repo, function(logs, err)
    if not logs then
      return util.msg(('failed to get CI log: %s'):format(err), vim.log.levels.WARN)
    end
    render_ci_log(buf, logs)
  end)
end

--- Concurrently pre-fetches CI logs up to `limit` jobs into hidden `prlogs/…` buffers.
--- - Skips already-rendered logs.
--- - In-progress jobs count toward `limit` but are not fetched.
local function preload_ci_logs(pr_id, repo, ci_jobs, limit)
  limit = math.min(limit or 5, #ci_jobs)
  local top = {}
  for i = 1, limit do
    -- Touch the prlogs/ buf so its key exists in `state.bufs`.
    state.init_buf('prlogs', nil, repo, ci_jobs[i].databaseId, { id = pr_id })
    if ci_jobs[i].conclusion then
      table.insert(top, ci_jobs[i])
    end
  end
  --- @param job CIJob
  local function should_skip(job)
    local buf = state.get_buf('prlogs', repo, job.databaseId, false)
    return buf ~= nil and (state.get_b_guh(buf) or {}).chan ~= nil and vim.api.nvim_buf_line_count(buf) > 1 -- buffer is non-empty
  end
  gh.get_pr_ci_logs(top, repo, should_skip, function(job, logs, err)
    local buf = state.get_buf('prlogs', repo, job.databaseId, false)
    if not buf then
      return -- Buf was wiped (e.g. user closed it) while the fetch was in flight.
    end
    if not logs then
      -- Failure: leave the empty buf (+ unset `b:guh.chan`). Future attempts will reuse the buf.
      util.log('preload_ci_logs failed', { job = job.name, err = err })
      return
    end
    render_ci_log(buf, logs)
  end)
end

--- Reads `ci_jobs` from cached `pr_data`. Fetches `pr_data` first if missing. Invokes `on_jobs(jobs)`.
---
--- @param pr_id integer
--- @param repo string "owner/name"
--- @param on_jobs fun(jobs: CIJob[])
local function with_ci_jobs(pr_id, repo, on_jobs)
  local function dispatch(pr, err)
    if not pr then
      return util.msg(err or ('PR #%s not found'):format(pr_id), vim.log.levels.ERROR)
    end
    local jobs = pr.ci_jobs or {}
    if #jobs == 0 then
      return util.msg(('No (non-skipped) CI jobs for PR #%s'):format(pr_id), vim.log.levels.WARN)
    end
    on_jobs(jobs)
  end
  local pr = state.get_pr_data(repo, pr_id)
  if pr then
    return dispatch(pr)
  end
  gh.get_pr_data(pr_id, repo, nil, dispatch)
end

--- Navigates to the next/previous CI job's logs, relative to the current `prlogs/…` buffer.
--- @param delta integer # +1 for next, -1 for previous.
local function show_next_ci_job(delta)
  local _, id, repo = require_pr()
  local b = vim.b.guh or {}
  -- Get the databaseId from the `…/prlogs/<databaseId>` bufname.
  local job_id = tonumber(b.bufkey and b.bufkey:match('/(%d+)$'))

  with_ci_jobs(id, repo, function(jobs)
    local cur_idx
    for i, j in ipairs(jobs) do
      if j.databaseId == job_id then
        cur_idx = i
        break
      end
    end
    local idx = (cur_idx or (delta > 0 and 0) or (#jobs + 1)) + delta
    if idx < 1 or idx > #jobs then
      return util.msg(('No %s CI job'):format(delta > 0 and 'next' or 'previous'))
    end
    show_ci_log(jobs[idx], id, repo)
  end)
end

--- Navigates to the next/previous "thing":
--- - In a `pr/…`, `prdiff/…` `prcomments/…` buf: navigates to first/last commit.
--- - In a `commit/…` buf: navigates to next/prev commit.
--- - In a `prlogs/…` buf: navigates next/prev CI job.
---
--- @param delta integer # +1 for next, -1 for previous.
function M.show_next(delta)
  local feat, id, repo, commit_idx = require_pr()
  if feat == 'prlogs' then
    return show_next_ci_job(delta)
  end

  local pr_data = state.get_pr_data(repo, id)
  local commits = pr_data and pr_data.commits
  if not commits or #commits == 0 then
    error('guh: No commits found ("R" to refresh)', 0)
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
  local _, id, repo = require_pr()

  local labels = {
    ['approve'] = { gerund = 'Approving', past = 'Approved' },
    ['comment'] = { gerund = 'Posting review on', past = 'Posted review on' },
    ['request-changes'] = { gerund = 'Requesting changes on', past = 'Requested changes on' },
  }

  local function do_action(action)
    local L = labels[action]
    local msg = ('%s PR #%s | ZZ to submit (ZQ to abort)'):format(L.gerund, id)
    -- Prefill ":+1:" in the Approve body, so the user can Approve without writing a comment. #64
    local content = action == 'approve' and { ':+1:' } or { '' }
    comments.edit_comment('review', id, content, { { msg, 'Comment' } }, function(input)
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

  local actions = { 'approve', 'comment', 'request-changes' }
  local count = vim.v.count
  if count >= 1 and count <= #actions then
    return do_action(actions[count])
  end

  vim.ui.select(actions, { prompt = ('Review PR #%s:'):format(id) }, function(action)
    if action then
      do_action(action)
    end
  end)
end

--- Refreshes the specified `guh://*` buffer, or current buffer if `target` is nil.
---
--- For PR bufs (`pr`/`prdiff`/`prcomments`): eagerly reloads data into all 3 bufs without changing
--- the window/buf layout.
---
--- @param target? { feat?: Feat, id?: integer|string, repo?: string }
function M.refresh(target)
  target = target or {}
  local feat = target.feat or util.require_b_guh({ 'feat' })
  if not feat then
    return
  end
  if feat == 'status' then
    local status_buf = state.get_buf('status', nil, 'all', false)
    if status_buf then
      state.invalidate(status_buf)
    end
    return M.show_status(true)
  end
  local b = vim.b.guh or {}
  local id = target.id or b.id
  local repo = target.repo or b.repo

  if feat == 'pr' or feat == 'prdiff' or feat == 'prcomments' or feat == 'prlogs' then
    -- Reload all "PR bufs" (pr/ + prdiff/ + prcomments/), without changing win/buf layout.
    -- Note: `preload_ci_logs` only refetches per-job if the job's `prlogs/` buf is not yet
    -- rendered AND the job has a `conclusion` (not "in_progress").
    local pr_buf = state.get_buf('pr', repo, id, false)
    if pr_buf then
      state.invalidate(pr_buf)
    end
    M.show_pr(id, repo, nil)
  elseif feat == 'issue' then
    local issue_buf = state.get_buf('issue', repo, id, false)
    if issue_buf then
      state.invalidate(issue_buf)
    end
    M.show_issue(id, repo, true)
  else
    M.select(feat, id, repo)
  end
end

--- Performs the "merge PR" action. Shows a vim.ui.select picker unless `[count]` was given.
function M.merge_pr()
  local _, id, repo = require_pr()

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
    gh.get_pr_data(id, repo, nil, function(pr, err)
      if not pr then
        return util.msg(err or ('PR #%s not found'):format(id), vim.log.levels.ERROR)
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
          -- Fall back to the PR description if the commit-derived body is blank/whitespace.
          if vim.trim(body or '') == '' then
            body = pr.body or ''
          end
        else
          error(('unknown method: %s'):format(method))
        end
        local text = ('%s\n\n%s'):format(subject, body):gsub('\r', '')
        local content = vim.split(text, '\n', { plain = true })
        local heading = {
          { ('[%s]'):format(choice), admin and 'ErrorMsg' or 'Comment' },
          { ' | First line = subject; rest = body | ZZ to merge (ZQ to abort)', 'Comment' },
        }
        comments.edit_comment('merge', id, content, heading, function(input)
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

  vim.ui.select(choices, { prompt = ('Merge PR #%s:'):format(id) }, function(choice)
    if choice then
      with_choice(choice)
    end
  end)
end

--- @param focus boolean
--- @param repo? string Optional "owner/name" repo.
function M.show_status(focus, repo)
  repo = repo or resolve_repo()
  local buf = state.init_buf('status', focus, nil, 'all', { repo = repo })
  local cmds = { { 'gh', 'status' } }
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
      {{"\nOpen PRs (last-updated):\n" -}}
      {{range .data.repository.pullRequests.nodes}}{{printf "  %-7s%s\n" (printf "#%v" .number) .title}}{{end -}}
      {{"\nOpen issues (last-updated):\n" -}}
      {{range .data.repository.issues.nodes}}{{printf "  %-7s%s\n" (printf "#%v" .number) .title}}{{end}}
    ]]
    )
    table.insert(cmds, { 'gh', 'pr', 'status', '--repo', repo })
    table.insert(cmds, {
      'gh',
      'api',
      'graphql',
      '-f',
      'owner=' .. owner,
      '-f',
      'name=' .. name,
      '-f',
      'query=' .. query,
      '--template',
      tmpl,
    })
  end
  util.run_term_cmds(buf, { pty = true }, cmds, function()
    util.set_default_keymaps(buf)
  end)
end

--- @param id integer
--- @param repo string "owner/name"
--- @param focus boolean
function M.show_issue(id, repo, focus)
  local buf = state.init_buf('issue', focus, repo, id)
  util.run_term_cmds(buf, { pty = true }, { gh.cmd(repo, 'issue', 'view', tostring(id), '--comments') }, function()
    util.set_default_keymaps(buf)
  end)
end

--- Shows PR details + the most-recent commits (since the last force-push).
---
--- - Loads the prdiff/ + prcomments/ buffers also.
--- - Preloads CI logs (idempotent: `preload_ci_logs` skips per-job if already rendered).
---
--- @param id integer
--- @param repo string "owner/name"
--- @param focus? boolean
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
  util.run_term_cmds(buf, { pty = true }, {
    gh.cmd(repo, 'pr', 'view', '--comments', tostring(id)),
    gh.cmd(repo, 'pr', 'view', tostring(id), '--json', 'commits', '--template', commits_tmpl),
  }, function()
    util.set_default_keymaps(buf)
    -- Poll `state.get_pr_data` (populated by `load_pr`) until ready.
    local tries = 0
    local function set_winbar()
      tries = tries + 1
      local pr = state.get_pr_data(repo, id)
      local win = vim.fn.win_findbuf(buf)[1]
      if pr and pr.title and win then
        util.show_winbar(win, {
          { ('PR #%s | "%s"'):format(id, pr.title), 'Comment' },
        })
      elseif tries < 40 then
        vim.defer_fn(set_winbar, 200) -- Retry...
      end
    end
    set_winbar()
  end)

  -- Eagerly load the prdiff/ buf in the background (not displayed), but only if its guh:// buffer
  -- is not already loaded. "Refresh" (R) forces reload by calling `state.invalidate(pr_buf)`.
  if not state.get_pr_data(repo, id) then
    M.load_pr({ id = id, repo = repo }, function(_, pr_data)
      -- `preload_ci_logs` is idempotent: skips per-job if already rendered, and skips "in_progress" jobs.
      -- Calling on every refresh picks up newly-completed jobs without needing a HEAD-changed gate.
      preload_ci_logs(id, repo, pr_data.ci_jobs or {})
    end)
  end
end

--- Loads (maybe-cached) PR data into prdiff/, prcomments/ buffers WITHOUT displaying them.
--- - Outdated-unresolved diff + comments are shown at top.
--- - Current diff + comments are shown after that.
--- - "Viewed" files collapse to a `(viewed) <path>` line.
--- - Diff + comments are presented as 2 'scrollbind' windows.
---
--- @param opts? { id?: integer|string, repo?: string, args?: string }
--- @param on_done? fun(buf: integer, pr_data: PullRequest, n_files: integer, n_viewed_threads: integer)
function M.load_pr(opts, on_done)
  local _, id, repo = require_pr(opts)
  local buf = state.init_buf('prdiff', nil, repo, id) -- focus=nil (no display)

  local progress = util.new_progress_report('Loading PR...', buf)
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
    comments.load_pr_comments(id, repo, buf, pr_data, threads, n_files, n_viewed_threads)
    -- Update `b:guh.pr_data` so the display step doesn't attempt to re-fetch.
    -- Use Vimscript to avoid re-serializing pr_data.
    -- TODO: https://github.com/neovim/neovim/issues/40159
    local pr_buf = state.get_buf('pr', repo, id, false)
    if pr_buf and vim.b[pr_buf].guh and vim.b[pr_buf].guh.pr_data then
      vim.api.nvim_buf_call(pr_buf, function()
        vim.cmd(('let b:guh.pr_data.n_files = %d'):format(n_files))
        vim.cmd(('let b:guh.pr_data.n_viewed_threads = %d'):format(n_viewed_threads))
      end)
    end
    progress('success')
    if on_done then
      on_done(buf, pr_data, n_files, n_viewed_threads)
    end
  end

  -- 1. Fetch PR data. Prefers cached `b:guh.pr_data`; callers force a refetch by clearing the cache.
  gh.get_pr_data(id, repo, nil, function(pr, err)
    if not pr then
      return progress('failed', nil, '%s', err or ('PR #%s not found'):format(id))
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

--- This is only used by "<Plug>(guh-diff)" now...
function M.show_pr_diff(opts)
  local _, id, repo = require_pr(opts)
  local buf = state.init_buf('prdiff', true, repo, id) -- focus=true

  -- Fast path: use the cached `b:guh.pr_data`; display without re-fetching.
  local pr_data = state.get_pr_data(repo, id)
  if pr_data and pr_data.n_files and pr_data.n_viewed_threads then
    return comments.show_pr_comments(id, repo, buf, pr_data, pr_data.n_files, pr_data.n_viewed_threads)
  end

  M.load_pr(opts, function(prdiff_buf, pr_data_, n_files, n_viewed_threads)
    comments.show_pr_comments(id, repo, prdiff_buf, pr_data_, n_files, n_viewed_threads)
  end)
end

--- Posts a file comment on the diff-line at cursor.
---
--- @param pr_id integer PR id
--- @param repo string "owner/name"
--- @param line1 integer 1-indexed line
--- @param line2 integer 1-indexed line
local function new_comment(pr_id, repo, line1, line2)
  local buf = vim.api.nvim_get_current_buf()
  local info = comments.prepare_to_comment(buf, line1, line2)
  if not info then
    return
  end
  util.hl_flash(buf, line1 - 1, line2 - 1)
  gh.get_pr_data(pr_id, repo, nil, function(pr, err)
    if not pr then
      return util.msg(err or ('PR #%s not found'):format(pr_id), vim.log.levels.ERROR)
    end
    local range = info.start_line == info.end_line and tostring(info.end_line)
      or ('%d..%d'):format(info.start_line, info.end_line)
    local infomsg = {
      { 'Comment on ', 'Comment' },
      { ('%s:%s'):format(info.file, range), 'Directory' },
      { ' | ZZ to send (ZQ to abort)', 'Comment' },
    }
    vim.schedule(function()
      comments.edit_comment('comment', pr_id, { '' }, infomsg, function(input)
        local progress = util.new_progress_report('Sending comment...', vim.api.nvim_get_current_buf())
        gh.new_comment(pr, input, info.file, info.start_line, info.end_line, info.side, repo, function(resp)
          if resp['errors'] == nil then
            progress('success', nil, 'Comment sent.')
            M.refresh({ feat = 'pr', id = pr_id, repo = repo })
          else
            progress('failed', nil, 'Failed to send comment.')
          end
        end)
      end)
    end)
  end)
end

--- Posts a top-level comment on the current PR or issue.
local function comment_top()
  local feat, id, repo = resolve_pr()
  local kind = feat == 'issue' and 'issue' or 'pr'

  comments.edit_comment('comment', id, { '' }, nil, function(input)
    local progress = util.new_progress_report('Sending comment...', vim.api.nvim_get_current_buf())
    gh.new_top_comment(kind, id, repo, input, function(ok, stderr)
      if ok then
        progress('success', nil, 'Comment sent.')
        M.refresh({ feat = (kind == 'issue' and 'issue' or 'pr'), id = id, repo = repo })
      else
        progress('failed', nil, ('Failed to send comment: %s'):format(vim.trim(stderr or '')))
      end
    end)
  end)
end

--- Implements `:GuhComment`.
---
--- - `:%GuhComment` (range = whole buffer): post a top-level comment on the current PR/issue.
--- - `:[range]GuhComment`: create or update comment at the given range.
--- - `:[range]GuhComment!`: delete a comment at the given (single-line) range.
---
--- @param args vim.api.keyset.create_user_command.command_args
function M.comment(args)
  assert(args and args.line1 and args.line2)
  if args.bang then
    if (args.range or 0) == 0 then
      return util.msg('GuhComment!: [range] is required', vim.log.levels.ERROR)
    end
    if args.line1 ~= args.line2 then
      return util.msg('GuhComment!: [range] must be a single line', vim.log.levels.ERROR)
    end
    return comments.delete_comment(args.line1)
  end

  -- `:%GuhComment` (entire buffer): top-level/overview comment.
  if (args.range or 0) > 0 and args.line1 == 1 and args.line2 == vim.fn.line('$') then
    return comment_top()
  end

  local feat, id, repo = require_pr()
  if feat == 'prcomments' then
    return comments.update_comment(args.line1)
  end

  new_comment(id, repo, args.line1, args.line2)
end

--- Runs `gh pr edit <id>` (or `gh issue edit <id>`) in a :terminal.
function M.edit_pr()
  local feat, id, repo = resolve_pr()
  local kind = feat == 'issue' and 'issue' or 'pr'
  local buf = state.init_buf('edit', true, repo, id)
  local cmd = gh.cmd(repo, kind, 'edit', tostring(id))
  vim.api.nvim_open_tabpage(buf, true, {})
  util.set_default_keymaps(buf)
  vim.fn.jobstart(cmd, {
    term = true,
    on_exit = function(_, _exitcode)
      vim.cmd.stopinsert()
      vim.api.nvim_buf_delete(buf, { force = true })
    end,
  })
end

--- Toggles the "Viewed" state of the file at cursor in a prdiff/ buffer.
function M.toggle_viewed()
  local _, id, repo = require_pr()
  local buf = vim.api.nvim_get_current_buf()
  local path, quasi = comments.jump_to_file_heading(buf)
  if not path then
    return util.msg('No file at cursor', vim.log.levels.WARN)
  end
  -- Flash curline (filepath heading after `jump_to_diff_file`).
  util.hl_flash(buf, vim.fn.line('.') - 1, vim.fn.line('.') - 1)

  local pr_data = state.get_pr_data(repo, id)
  if not pr_data or not pr_data.node_id then
    return util.msg(('PR #%s not loaded? ("R" to refresh)'):format(id), vim.log.levels.ERROR)
  end
  -- `markFileAsViewed` cannot work with renamed/removed files.
  if not (pr_data.file_paths or {})[path] then
    if quasi then
      return util.msg(
        ('File "%s" is not in the PR (%s thread). Use "cr" to resolve the thread instead.'):format(path, quasi),
        vim.log.levels.WARN
      )
    end
    return util.msg(('"%s" is not a current file in PR #%s'):format(path, id), vim.log.levels.WARN)
  end
  local viewed = not (pr_data.viewed and pr_data.viewed[path])
  local done = util.progress((viewed and 'Marking' or 'Unmarking') .. ' as viewed: ' .. path)
  gh.set_file_viewed(pr_data.node_id, path, viewed, function(resp)
    if resp['errors'] ~= nil then
      done('failed')
      util.msg(('Failed to %s viewed: %s'):format(viewed and 'mark' or 'unmark', path), vim.log.levels.ERROR)
      return
    end
    done('success')
    M.refresh({ feat = 'pr', id = id, repo = repo })
  end)
end

--- Reruns CI for the current PR. Shows a vim.ui.select picker unless `[count]` was given.
---
--- @param opts? { id?: integer|string, repo?: string, args?: string }
function M.ci_rerun(opts)
  local feat, id, repo = require_pr(opts)
  local b = vim.b.guh or {}
  local cur_log_job_id = feat == 'prlogs' and tonumber((b.bufkey or ''):match('/(%d+)$')) or nil

  local function do_rerun(run_id, job_id, label, on_done)
    if not run_id then
      util.msg(('Cannot rerun %s: missing GitHub Actions run id ("R" to refresh)'):format(label), vim.log.levels.ERROR)
      if on_done then
        on_done(false)
      end
      return
    end
    gh.rerun_ci(run_id, repo, job_id, function(ok, stderr)
      if not ok then
        util.msg(('CI rerun failed for %s: %s'):format(label, vim.trim(stderr or '')), vim.log.levels.ERROR)
      end
      if on_done then
        on_done(ok)
      end
    end)
  end

  local function rerun_current_job()
    if not cur_log_job_id then
      return util.msg('No current CI log job; use `dl` to open a CI log first', vim.log.levels.ERROR)
    end
    with_ci_jobs(id, repo, function(jobs)
      local job = vim.iter(jobs):find(function(j)
        return j.databaseId == cur_log_job_id
      end)
      if not job then
        return util.msg('Unknown CI job for this log buffer', vim.log.levels.ERROR)
      end
      local done = util.progress(('Rerunning CI job "%s"…'):format(job.name))
      return do_rerun(job.runId, job.databaseId, job.name, function(ok)
        done(ok and 'success' or 'failed')
        if ok then
          util.msg(('Rerunning CI job "%s"'):format(job.name))
        end
      end)
    end)
  end

  local function rerun_all_failed()
    local function dispatch(pr, err)
      if not pr then
        return util.msg(err or ('PR #%s not found'):format(id), vim.log.levels.ERROR)
      end
      local failed_job = vim.iter(pr.ci_jobs or {}):find(function(j)
        return j.runId and j.conclusion and j.conclusion ~= 'success'
      end)
      if not failed_job then
        return util.msg(('No failed CI jobs for PR #%s ("R" to refresh)'):format(id), vim.log.levels.WARN)
      end

      local run_id = failed_job.runId
      local done = util.progress(('Rerunning failed CI for PR #%s…'):format(id))
      do_rerun(run_id, nil, ('run %s'):format(run_id), function(ok)
        done(ok and 'success' or 'failed')
        if ok then
          util.msg(('Rerunning failed CI for run %s on PR #%s'):format(run_id, id))
        end
      end)
    end

    local pr = state.get_pr_data(repo, id)
    if pr then
      return dispatch(pr)
    end
    gh.get_pr_data(id, repo, nil, dispatch)
  end

  local actions = {
    { label = 'current job', run = rerun_current_job },
    { label = 'failed jobs', run = rerun_all_failed },
  }
  local count = vim.v.count
  if count >= 1 and count <= #actions then
    return actions[count].run()
  end

  vim.ui.select(actions, {
    prompt = ('Rerun CI for PR #%s:'):format(id),
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if action then
      action.run()
    end
  end)
end

--- Shows a menu of most-recent CI logs for each (matrix-expanded) job type.
function M.ci_logs_pick(opts)
  local _, id, repo = require_pr(opts)
  with_ci_jobs(id, repo, function(jobs)
    vim.ui.select(jobs, {
      prompt = ('CI jobs for PR #%s'):format(id),
      format_item = function(j)
        local status = j.conclusion or j.status or '?'
        local label = status == 'success' and '✅'
          or status == 'in_progress' and '⏳'
          or status == 'failure' and '❌'
          or '?'
        return ('%s %s'):format(label, j.name)
      end,
    }, function(picked)
      if picked then
        show_ci_log(picked, id, repo)
      end
    end)
  end)
end

return M
