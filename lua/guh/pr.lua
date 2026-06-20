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
  if
    not optional
    and not id
    and b_guh
    and (b_guh.feat == 'issue' or b_guh.feat == 'status' or b_guh.feat == 'repo')
  then
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

--- Returns an "Unread" 'winbar' chunk if the slug is in the `b:guh.notifications` map.
---
--- @param repo string "owner/name"
--- @param id integer|string
--- @return [string, string?]?
local function notif_chunk(repo, id)
  local status_buf = state.get_buf('status', nil, 'all', false)
  local notif = status_buf and state.get_b_key(status_buf, { 'guh', 'notifications', ('%s#%s'):format(repo, id) })
  return notif and { 'Unread', 'WarningMsg' } or nil
end

--- Sets the 'winbar' for a pr/issue/repo/status view, in every window displaying `buf`.
---
--- @param buf integer
--- @param feat Feat
--- @param id any
--- @param repo? string
--- @param pr? PullRequest
local function set_winbar(buf, feat, id, repo, pr)
  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    return
  end
  local st = pr and gh.pr_state_label(pr) or ''
  local chunks = {
    { ('%s %s%s '):format(feat:upper(), (feat == 'pr' or feat == 'issue') and '#' or '', id) },
    { st, gh.state_hl[st] },
  }
  -- Flag PRs targeting a non-default branch.
  if pr and pr.defaultBranch and pr.baseRefName ~= pr.defaultBranch then
    chunks[#chunks + 1] = { ' | ' }
    chunks[#chunks + 1] = { ('Target: %s'):format(pr.baseRefName), 'WarningMsg' }
  end
  local nc = (feat == 'pr' or feat == 'issue') and notif_chunk(repo, id)
  if nc then
    chunks[#chunks + 1] = { ' | ' }
    chunks[#chunks + 1] = nc
  end
  if pr then
    chunks[#chunks + 1] = { (' | %s'):format(pr.title) }
  end
  for _, win in ipairs(wins) do
    util.show_winbar(win, chunks)
  end
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
  local focus = (function()
    if feat then
      return nil -- "Programmatic" invocation used by reload(), which doesn't want to change layout.
    end
    return not window_mod -- If a mod was given (`:vertical Guh …`), don't navigate to an existing window.
  end)()

  -- Resolve target + repo (+ PR/issue probe) BEFORE potential `:new` split, so we can check `b:guh`.
  local target = (function()
    if feat == 'status' then
      return { status = true }
    elseif feat == 'repo' then
      return {} -- Repo overview (no id).
    elseif feat then
      -- Programmatic caller provided (feat, id, repo) directly. Skip parsing.
      return { id = id, is_pr = ({ pr = true, prdiff = true, prcomments = true, prlogs = true, issue = false })[feat] }
    elseif #arg > 0 then
      return util.parse_target(arg)
    end
  end)() --[[@type GuhTarget?]]

  if #arg > 0 and not target then -- `:Guh <garbage>`: parse failed.
    util.msg(('failed to parse: %s'):format(arg), vim.log.levels.ERROR)
    return
  end

  -- Resolve the repo once. Skip for guh://status (repo-less); prefer an explicit owner/repo target.
  if not (target and target.status) then
    repo = repo or (target and target.owner and ('%s/%s'):format(target.owner, target.repo)) or resolve_repo()
  end
  -- PR/issue/commit target needs a repo; bare `:Guh` falls back to status if none resolves.
  if target and (target.id or target.sha) and not repo then
    util.msg('Failed to get repo info', vim.log.levels.ERROR)
    return
  end

  local function dispatch(is_pr)
    if window_mod then
      vim.cmd((cmdargs.mods or '') .. ' new')
    end
    if target and target.status then
      M.show_status(focus) -- Explicit `guh://status`.
    elseif not target and repo then
      M.show_repo(focus, repo) -- No args, but resolved a repo.
    elseif not target then
      M.show_status(focus) -- No args, no repo: guh://status.
    elseif target.sha then
      M.show_commit(target.sha, repo, focus)
    elseif not target.id then
      M.show_repo(focus, repo) -- Repo target ("owner/repo", "https://github.com/owner/repo").
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
    elseif state.get_b_key(state.get_buf('status', nil, 'all', false), { 'guh', 'notifications', arg }) then
      local notif = state.get_b_key(state.get_buf('status', nil, 'all', false), { 'guh', 'notifications', arg })
      dispatch(notif.is_pr)
    else -- Probe PR-vs-issue. Async so the hl_flash() highlight works.
      util.system({ 'gh', 'api', ('repos/%s/pulls/%s'):format(repo, target.id) }, nil, function(r)
        util.log('select.probe.done', { code = r.code })
        dispatch(r.code == 0)
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
--- @param focus? boolean
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
  util.system(cmd, nil, function(r)
    if r.code ~= 0 then
      return done('failed', vim.trim(r.stderr or ''))
    end
    -- Patch format's first line is "From <full-sha> Mon Sep 17 00:00:00 2001".
    local full_sha = r.stdout:match('^From%s+(%x+)') or sha
    local buf = state.init_buf('commit', focus, repo, full_sha, { id = full_sha })
    local lines = vim.split(r.stdout, '\n', { plain = true, trimempty = true })
    util.buf_set_readonly_lines(buf, lines, 'gitcommit')
    util.set_default_keymaps(buf)
    done('success')
  end)
end

--- Opens the full contents of the diff-file at cursor (in a prdiff/ buffer), at the PR's head commit.
function M.show_file()
  local _, id, repo = require_pr()
  local path, quasi = comments.find_file_heading(0, false)
  if not path then
    return util.msg('No file at cursor', vim.log.levels.WARN)
  elseif quasi then
    return util.msg(('Cannot fetch file for %s diff'):format(quasi), vim.log.levels.WARN)
  end
  local pr_data = state.get_pr_data(repo, id)
  if not pr_data or not pr_data.headRefOid then
    return util.msg(('PR #%s not loaded? ("R" to refresh)'):format(id), vim.log.levels.ERROR)
  end
  local sha = pr_data.headRefOid
  local key = ('%s/%s'):format(sha, path) -- Key by `<sha>/<path>` so each (commit, file) gets its own reusable buffer.
  local existing = state.get_buf('file', repo, key, false)
  if existing and vim.api.nvim_buf_line_count(existing) > 1 then
    state.init_buf('file', true, repo, key, { id = id }) -- Already loaded; just navigate.
    return
  end
  local done = util.progress(('Loading %s @ %s...'):format(path, sha:sub(1, 7)))
  local cmd =
    { 'gh', 'api', ('repos/%s/contents/%s?ref=%s'):format(repo, path, sha), '-H', 'Accept: application/vnd.github.raw' }

  util.system(cmd, nil, function(r)
    if r.code ~= 0 then
      return done('failed', vim.trim(r.stderr or ''))
    end
    local buf = state.init_buf('file', true, repo, key, { id = id })
    local lines = vim.split(r.stdout, '\n', { plain = true })
    util.buf_set_readonly_lines(buf, lines, vim.filetype.match({ filename = path }) or '')
    util.set_default_keymaps(buf)
    done('success')
  end)
end

--- Gets the status emoji for a CI job.
--- @param job CIJob
local function ci_icon(job)
  if not job.conclusion then
    return '⏳' -- No `conclusion` until job finishes (still-running / in-progress).
  elseif job.conclusion == 'success' or job.conclusion == 'neutral' or job.conclusion == 'skipped' then
    return '✅'
  end
  return '❌'
end

--- Renders `logs` into a `prlogs/…` terminal-buf, or does nothing if `b:guh.chan` is already set.
local function render_ci_log(buf, logs)
  if (state.get_b_guh(buf) or {}).chan then
    return
  end
  local chan = vim.api.nvim_open_term(buf, {})
  vim.api.nvim_chan_send(chan, logs)
  -- state.set_b_key(buf, 'guh.chan', chan)
  vim.fn.chanclose(chan)
  util.set_default_keymaps(buf)
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
  util.show_winbar(0, {
    { ('Logs | PR #%s | '):format(pr_id) },
    { ci_icon(job) },
    { (' "%s"'):format(job.name) },
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

--- Toggles a PR's "Draft" / "Ready for review" state.
---
--- @param id integer
--- @param repo string "owner/name"
--- @param is_draft boolean current state (true = currently draft).
local function toggle_draft(id, repo, is_draft)
  local label = is_draft and 'Set as Ready' or 'Set as Draft'
  local done = util.progress(('%s PR #%s…'):format(label, id))
  gh.set_pr_draft(id, repo, not is_draft, function(ok, stderr)
    if ok then
      done('success')
      M.refresh({ feat = 'pr', id = id, repo = repo })
    else
      done('failed', vim.trim(stderr))
    end
  end)
end

--- Performs the "review PR" action. Shows a vim.ui.select picker unless `[count]` was given.
---
--- Each action opens an editable `guh://<owner>/<repo>/review/<id>` buffer for the (optional) body.
function M.review_pr()
  local _, id, repo = require_pr()

  local function do_action(label)
    local gh_action = label:lower()
    local heading = ('%s PR #%s'):format(label, id)
    local msg = ('%s | ZZ to submit (ZQ to abort)'):format(heading)
    -- Prefill ":+1:" in the Approve body, so the user can Approve without writing a comment. #64
    local content = label == 'Approve' and { ':+1:' } or { '' }
    comments.edit_comment('review', id, content, { { msg } }, function(input)
      local body = vim.trim(input)
      local done = util.progress(('%s…'):format(heading))
      gh.review_pr(id, repo, gh_action, body, function(ok, stderr)
        if ok then
          done('success')
        else
          done('failed', vim.trim(stderr))
        end
      end)
    end)
  end

  -- Menu item 4 toggles "Draft"/"Ready".
  local pr_data = state.get_pr_data(repo, id) or {}
  local is_draft = pr_data.isDraft == true
  local draft_label = is_draft and 'Set as Ready' or 'Set as Draft'

  local actions = { 'Approve', 'Comment', 'Request-changes', draft_label }
  local count = vim.v.count
  if count >= 1 and count <= #actions then
    if actions[count] == draft_label then
      return toggle_draft(id, repo, is_draft)
    end
    return do_action(actions[count])
  end

  vim.ui.select(actions, { prompt = ('Review PR #%s:'):format(id) }, function(action)
    if not action then
      return
    elseif action == draft_label then
      toggle_draft(id, repo, is_draft)
    else
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
  local b = vim.b.guh or {}
  local id = target.id or b.id
  local repo = target.repo or b.repo

  -- Clear the cached `b:guh` state (if any), to force a reload.
  -- PR sub-views (prdiff/prcomments/prlogs) cache on the pr/ buf; status/repo key by "all".
  local cache_feat = (feat == 'prdiff' or feat == 'prcomments' or feat == 'prlogs') and 'pr' or feat
  local cache_id = (feat == 'status' or feat == 'repo') and 'all' or id
  local buf = state.get_buf(cache_feat, repo, cache_id, false)
  if buf then
    state.invalidate(buf)
  end
  -- This "programmatic" select() invocation will implicitly pass focus=nil (for window layout).
  M.select(feat, id, repo)
end

--- Performs the "merge PR" action. Shows a vim.ui.select picker unless `[count]` was given.
function M.merge_pr()
  local _, id, repo = require_pr()

  local function do_merge(choice, subject, body)
    local method = choice:match('^(%S+)')
    local admin = choice:find('--admin', 1, true) ~= nil
    local done = util.progress(('Merging PR #%s (%s)…'):format(id, choice))
    gh.merge_pr(id, repo, method, subject, body, admin, function(ok, stderr)
      if ok then
        done('success')
      else
        done('failed', vim.trim(stderr))
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
          { ('[%s]'):format(choice), admin and 'ErrorMsg' or nil },
          { ' | First line = subject; rest = body | ZZ to merge (ZQ to abort)' },
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

--- Implements `<Plug>(guh-up)` ("-"): navigates to the "parent" of a `guh://` buffer.
function M.go_up()
  local b = vim.b.guh or {}
  if b.feat == 'pr' or b.feat == 'issue' then
    M.show_repo(true, b.repo)
  elseif b.feat == 'prdiff' or b.feat == 'prcomments' or b.feat == 'prlogs' or b.feat == 'file' then
    M.show_pr(assert(vim._tointeger(b.id)), b.repo, true)
  elseif b.feat == 'commit' then
    local pr_id = find_pr_for_commit_sha(b.id)
    if pr_id then
      M.show_pr(pr_id, b.repo, true)
    else
      M.show_repo(true, b.repo)
    end
  elseif b.feat == 'repo' then
    M.show_status(true)
  end
end

--- Implements `guh://status` (global): the user's unread notifications across all repos.
---
--- @param focus? boolean
function M.show_status(focus)
  local buf = state.init_buf('status', focus, nil, 'all')
  if state.get_b_key(buf, { 'guh', 'notifications' }) then
    return -- Skip the re-fetch if already loaded.
  end
  set_winbar(buf, 'status', '', nil, nil)
  util.set_default_keymaps(buf)
  local done = util.progress('Loading notifications...')
  gh.get_user_notifs(buf, function(lines, err)
    if not lines then
      return done('failed', err)
    end
    util.buf_set_readonly_lines(buf, lines, '')
    done('success')
  end)
end

--- Implements `guh://<owner>/<repo>`: repo overview + the user's `gh pr status` for the repo.
---
--- @param focus? boolean
--- @param repo? string "owner/name"
function M.show_repo(focus, repo)
  repo = repo or resolve_repo()
  if not repo then
    return util.msg('Failed to resolve repo', vim.log.levels.ERROR)
  end
  local buf = state.init_buf('repo', focus, repo, 'all')
  local owner, name = repo:match('^([^/]+)/(.+)$')
  local query = vim.text.indent(
    0,
    [[
    query($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){
        defaultBranchRef{ target{ ... on Commit{ history(first:10){ nodes{ oid messageHeadline } } } } }
        pullRequests(first:10,states:OPEN,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number title}}
        issues(first:10,states:OPEN,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number title}}
      }
    }
  ]]
  )
  -- "#NNN" and commit-oid rows match `b:guh.repo` so <CR> opens them.
  local tmpl = vim.text.indent(
    0,
    [[
    {{"\nRecent commits:\n" -}}
    {{range .data.repository.defaultBranchRef.target.history.nodes}}{{printf "  %s  %s\n" (slice .oid 0 12) .messageHeadline}}{{end -}}
    {{"\nOpen PRs (last-updated):\n" -}}
    {{range .data.repository.pullRequests.nodes}}{{printf "  %-7s%s\n" (printf "#%v" .number) .title}}{{end -}}
    {{"\nOpen issues (last-updated):\n" -}}
    {{range .data.repository.issues.nodes}}{{printf "  %-7s%s\n" (printf "#%v" .number) .title}}{{end}}
  ]]
  )

  set_winbar(buf, 'repo', repo, repo, nil)

  util.set_default_keymaps(buf)
  util.run_cmds(buf, { term = true }, {
    {
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
    },
    { 'gh', 'pr', 'status', '--repo', repo },
  })
end

--- Implements "mark as read". Updates the `b:guh.notifications` map; does NOT refresh `guh://status`.
function M.set_read()
  local buf = vim.api.nvim_get_current_buf()
  local feat, id, repo = util.require_b_guh({ 'feat', 'id', 'repo' })
  if not feat then
    return
  end
  local slug = ('%s#%s'):format(repo, id)
  local status_buf = state.get_buf('status', nil, 'all', false)
  local notifs = status_buf and state.get_b_key(status_buf, { 'guh', 'notifications' })
  local notif = notifs and notifs[slug]
  if not notif then
    return util.msg(('No unread notification for: %s'):format(slug), vim.log.levels.WARN)
  end
  local done = util.progress(('Marking %s read…'):format(slug))
  gh.set_notif_read(notif.thread_id, function(ok, err)
    if not ok then
      return done('failed', err)
    end
    done('success')
    state.set_b_key(assert(status_buf), { 'guh', 'notifications', slug }, vim.NIL)
    set_winbar(buf, feat, id, repo, feat == 'pr' and state.get_pr_data(repo, id) or nil)
  end)
end

--- @param id integer
--- @param repo string "owner/name"
--- @param focus? boolean
function M.show_issue(id, repo, focus)
  local buf = state.init_buf('issue', focus, repo, id)
  set_winbar(buf, 'issue', id, repo)
  util.set_default_keymaps(buf)
  util.run_cmds(buf, { term = true }, { gh.cmd(repo, 'issue', 'view', tostring(id), '--comments') })
end

--- Formats an ISO-8601 timestamp as a relative "… ago" string (largest unit only, like gh's `timeago`).
local function reltime(iso)
  local t = iso and vim.fn.strptime('%Y-%m-%dT%H:%M:%S', iso) or 0
  if t == 0 then
    return '' -- empty / unparseable
  end
  local full = require('vim._core.time').fmt_rtime(math.max(0, os.time() - t))
  return full:match('^[^,]+') .. ' ago' -- Keep only the first (largest) unit.
end

--- "✓ Checks passing" / "✗ N/M checks failing" / "● N/M checks pending", or nil if there are no jobs.
--- @param jobs CIJob[]
local function checks_summary(jobs)
  if #jobs == 0 then
    return nil
  end
  local fail, pending = 0, 0
  for _, j in ipairs(jobs) do
    if not j.conclusion then
      pending = pending + 1
    elseif j.conclusion ~= 'success' and j.conclusion ~= 'neutral' and j.conclusion ~= 'skipped' then
      fail = fail + 1
    end
  end
  if fail > 0 then
    return ('✗ %d/%d Checks failing'):format(fail, #jobs)
  elseif pending > 0 then
    return ('● %d/%d Checks pending'):format(pending, #jobs)
  end
  return '✓ Checks passing'
end

--- "login (Display Name)" when a name is present, else "login" (for bots?).
local function who(login, name)
  return (name and name ~= '') and ('%s (%s)'):format(login, name) or login
end

--- Renders the PR header (title/author/diffstat/reactions) + raw markdown body from `pr_data`.
---
--- NOTE: Intentionally omits Reviewers/Assignees/Labels (seems useless, wait until someone actually wants this).
---
--- @param pr PullRequest
local function render_pr_header(pr)
  local author = pr.author or {}
  local n = #(pr.commits or {})

  local reactions = {}
  for _, g in ipairs(pr.reactions or {}) do
    local count = vim.tbl_get(g, 'reactors', 'totalCount') or 0
    if count > 0 then
      reactions[#reactions + 1] = ('%d %s'):format(count, gh.reaction_emoji[g.content] or g.content)
    end
  end

  local lines = {
    '# ' .. (pr.title or ''),
    '',
    (('- Author: %s %s')
      :format(who(author.login or '?', author.name), table.concat(reactions, ' • '))
      :gsub('%s+$', '')),
    ('- Date: %s'):format(reltime(pr.createdAt)),
    ('- Diff: +%d -%d, %d commit%s to `%s` from `%s`'):format(
      pr.additions or 0,
      pr.deletions or 0,
      n,
      n == 1 and '' or 's',
      pr.baseRefName or '?',
      pr.headRefName or '?'
    ),
    ('- CI: %s'):format(checks_summary(pr.ci_jobs or {}) or '?'),
  }

  -- Avoid extra blank lines if body is empty.
  local body = vim.trim((pr.body or ''):gsub('\r', '')) -- Strip CR within the (CRLF) body.
  vim.list_extend(lines, body ~= '' and { '', body, '' } or { '' })
  return table.concat(lines, '\n')
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
      {{printf "\n## Commits (%d)\n\n" (len .commits) -}}
      {{range .commits}}{{slice .oid 0 12}}  {{slice .committedDate 0 10}}  {{.messageHeadline}}{{"\n"}}{{end}}
    ]]
  )
  -- Render comments as raw markdown via a template (gh has no `--format=markdown`).
  local comments_tmpl = vim.text.indent(
    0,
    [[
      {{printf "\n## Discussion\n" -}}
      {{if .comments}}{{range .comments}}{{printf "\n*%s (%s) — %s*\n\n%s\n" .author.login .authorAssociation (timeago .createdAt) .body}}{{end}}{{else}}{{"\n*No comments*\n"}}{{end}}
    ]]
  )

  util.set_default_keymaps(buf)
  util.run_cmds(buf, {}, {
    -- Get the header+body in the pr_data query, bc "gh pr view" looks like shit.
    function(_, on_stdout, _, on_exit)
      local is_reload = not state.get_pr_data(repo, id)
      gh.get_pr_data(id, repo, nil, function(pr)
        on_stdout(nil, { pr and render_pr_header(pr) or 'FAILED render_pr_header' }) -- Note: Must send non-nil to on_stdout to allow it to advance.
        on_exit()
        -- `preload_ci_logs` is idempotent: skips per-job if already-rendered or "in_progress".
        if pr and is_reload then
          M.load_pr({ id = id, repo = repo }, function(_, pr2)
            preload_ci_logs(id, repo, pr2.ci_jobs or {})
          end)
        end
      end)
    end,
    gh.cmd(repo, 'pr', 'view', tostring(id), '--json', 'commits', '--template', commits_tmpl),
    gh.cmd(repo, 'pr', 'view', tostring(id), '--json', 'comments', '--template', comments_tmpl),
  }, function()
    vim._with({ buf = buf }, function()
      vim.cmd [[set breakindent nolist filetype=markdown]]
    end)
    set_winbar(buf, 'pr', id, repo, state.get_pr_data(repo, id))
    vim.api.nvim_buf_call(buf, function()
      vim.cmd([[syntax match GuhWarning /\<\(Checks pending\)/]])
      vim.cmd([[syntax match ErrorMsg /\<\(Checks failing\)/]])
      vim.cmd([[syntax match OkMsg /\<\(Checks passing\)/]])
    end)
  end)
end

--- Loads (maybe-cached) PR data into prdiff/, prcomments/ buffers WITHOUT presenting (focusing) them.
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
  util.set_default_keymaps(buf)

  -- Show "Loading…" only if we actually fetch.
  local cached = state.get_pr_data(repo, id)
  util.log(
    'load_pr',
    { id = id, repo = repo, cached = cached ~= nil, cached_diff = (cached and cached.diff_stdout) ~= nil }
  )
  local progress = (cached and cached.diff_stdout) and function() end or util.new_progress_report('Loading PR...', buf)
  progress('running')

  local pr_data --[[@type PullRequest?]]
  local diff_stdout
  local function try_render()
    if not pr_data or not diff_stdout then
      return
    end
    local pr_buf = state.get_buf('pr', repo, id, false)
    -- Cache the prdiff in `b:guh.pr_data`. Do this here so it runs only after `gh.get_pr_data` stored `pr_data`.
    if pr_buf and pr_data.diff_stdout ~= diff_stdout then
      state.set_b_key(pr_buf, { 'guh', 'pr_data', 'diff_stdout' }, diff_stdout)
    end
    local lines, threads, n_files, n_viewed_threads = comments.render_diff(pr_data, diff_stdout)
    util.log(('comment threads (total: %s)'):format(vim.tbl_count(threads)), threads)
    -- filetype=gitcommit enables plugins like https://github.com/barrettruth/diffs.nvim
    util.buf_set_readonly_lines(buf, lines, 'gitcommit')
    vim.api.nvim_buf_call(buf, function()
      -- Override the builtin `diffFile` highlight. But let GuhWarning win for its sub-spans.
      vim.cmd([[syntax match GuhDiffFile /^diff --git.*/ containedin=ALL]])
      vim.cmd([[syntax match GuhWarning /^(viewed)/ containedin=ALL]])
      -- Match offdiff file prefix ("outdated-3271868956:", "outside-3271868956:").
      vim.cmd([[syntax match GuhWarning /\<\(outdated\|outside\)\ze-\d\+:/ containedin=ALL]])
    end)
    comments.load_pr_comments(id, repo, buf, pr_data, threads, n_files, n_viewed_threads)
    -- Update `b:guh.pr_data` so the display step doesn't attempt to re-fetch.
    if pr_buf then
      state.set_b_key(pr_buf, { 'guh', 'pr_data', 'n_files' }, n_files)
      state.set_b_key(pr_buf, { 'guh', 'pr_data', 'n_viewed_threads' }, n_viewed_threads)
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
    diff_stdout = pr.diff_stdout or diff_stdout -- Fallback to the cached prdiff, if any.
    try_render()
  end)

  -- 2. Get the current PR diff, unless `gh.get_pr_data` found a cached one (synchronously).
  --    Caching `pr_data.diff_stdout` lets re-renders (e.g. toggling "Viewed") skip this.
  if not diff_stdout then
    util.system(gh.cmd(repo, 'pr', 'diff', tostring(id)), nil, function(r)
      if r.code ~= 0 then
        progress('failed', nil, vim.trim(r.stderr or ''))
        return
      end
      diff_stdout = r.stdout
      try_render()
    end)
  end
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
      { 'Comment on ' },
      { ('%s:%s'):format(info.file, range), 'Directory' },
      { ' | ZZ to send (ZQ to abort)' },
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
  local path, quasi, lnum = comments.find_file_heading(buf, true)
  if not path then
    return util.msg('No file at cursor', vim.log.levels.WARN)
  end
  util.hl_flash(buf, lnum - 1, lnum - 1) -- Flash the filepath heading.

  local pr_data, pr_buf = state.get_pr_data(repo, id)
  if not pr_data or not pr_data.node_id then
    return util.msg(('PR #%s not loaded? ("R" to refresh)'):format(id), vim.log.levels.ERROR)
  end
  -- `markFileAsViewed` cannot work with renamed/removed files.
  local local_only = quasi ~= nil
  if not local_only and not (pr_data.file_paths or {})[path] then
    return util.msg(('"%s" is not a current file in PR #%s'):format(path, id), vim.log.levels.WARN)
  end
  local viewed = not (pr_data.viewed and pr_data.viewed[path])

  -- Optimization: patch `viewed` locally, then re-render from cache.
  -- Do "optimistic" gh.set_file_viewed(); on failure, local state is stale until "Refresh".
  state.set_b_key(pr_buf, { 'guh', 'pr_data', 'viewed', path }, viewed or vim.NIL)

  local msg = ('%s%s: %s'):format(
    viewed and 'Viewed' or 'Unviewed',
    local_only and (' (%s file, Refresh will forget)'):format(quasi) or '',
    path
  )

  -- Re-render from cache.
  M.load_pr({ id = id, repo = repo }, function()
    util.msg(msg)
  end)
  -- Send API request for non-quasi files.
  if not local_only then
    local done = util.progress(msg)
    gh.set_file_viewed(pr_data.node_id, path, viewed, function(resp)
      done(resp['errors'] and 'failed' or 'success', util.gh_errors(resp))
      -- We intentionally do not refresh() here.
    end)
  end
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
      return on_done(false, ('Cannot rerun %s: missing GitHub Actions run id ("R" to refresh)'):format(label))
    end
    gh.rerun_ci(run_id, repo, job_id, function(ok, stderr)
      on_done(ok, not ok and vim.trim(stderr or '') or nil)
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
      return do_rerun(job.runId, job.databaseId, job.name, function(ok, err)
        done(ok and 'success' or 'failed', err)
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
      do_rerun(run_id, nil, ('run %s'):format(run_id), function(ok, err)
        done(ok and 'success' or 'failed', err)
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
        return ('%s %s'):format(ci_icon(j), j.name)
      end,
    }, function(picked)
      if picked then
        show_ci_log(picked, id, repo)
      end
    end)
  end)
end

return M
