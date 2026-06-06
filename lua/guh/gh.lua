local state = require('guh.state')
local util = require('guh.util')

require('guh.types')

local f = string.format

local M = {}

local function parse_or_default(str, default)
  local success, result = pcall(vim.json.decode, str)
  if success then
    return result
  end

  return default
end

--- Takes nested threads (GraphQL: `reviewThreads.nodes`) and produces a flat list of comments.
---
--- @return Comment[]
local function flatten_threads_to_comments(threads)
  local out = {}
  for _, thread in ipairs(threads or {}) do
    -- Drop resolved threads entirely.
    if not thread.isResolved then
      local nodes = vim.tbl_get(thread, 'comments', 'nodes') or {}
      local thread_id = nodes[1] and nodes[1].databaseId
      -- Reply comments on outdated threads carry no originalLine of their own;
      -- inherit from the head comment so they aren't filtered out below.
      local head_line = nodes[1] and nodes[1].originalLine
      local head_start = nodes[1] and nodes[1].originalStartLine
      local head_path = nodes[1] and nodes[1].path
      -- `diffSide` is a thread-level property in GraphQL; every comment in the thread inherits it.
      local c_side = thread.diffSide
      for _, c in ipairs(nodes) do
        local c_path = (not vim.isnil(c.path)) and c.path or head_path
        -- LEFT-side (deleted-line) comments, and outdated threads, have a null `line` on HEAD; fallback to `originalLine` then.
        local effective_line = (not vim.isnil(c.line)) and c.line
          or (not vim.isnil(c.originalLine)) and c.originalLine
          or head_line
        local effective_start = (not vim.isnil(c.startLine)) and c.startLine
          or (not vim.isnil(c.originalStartLine)) and c.originalStartLine
          or head_start
        if not vim.isnil(effective_line) and not vim.isnil(c_path) then
          local reply_to
          if not vim.isnil(c.replyTo) and c.replyTo.databaseId then
            reply_to = c.replyTo.databaseId
          end
          table.insert(out, {
            id = c.databaseId,
            html_url = c.url,
            user = { login = (not vim.isnil(c.author)) and c.author.login or '?' },
            body = c.body or '',
            diff_hunk = c.diffHunk or '',
            path = c_path,
            line = effective_line,
            start_line = effective_start,
            side = c_side,
            updated_at = c.updatedAt,
            in_reply_to_id = reply_to,
            outdated = thread.isOutdated or false,
            thread_id = thread_id,
          })
        end
      end
    end
  end
  return out
end

--- Builds a PR object from a `get_pr_data` result (GraphQL: `pullRequest`).
---
--- @return PullRequest
local function to_pr(node)
  local commits = {}
  for _, n in ipairs(vim.tbl_get(node, 'commits', 'nodes') or {}) do
    table.insert(commits, n.commit)
  end
  local viewed = {}
  for _, n in ipairs(vim.tbl_get(node, 'files', 'nodes') or {}) do
    if n.viewerViewedState == 'VIEWED' then
      viewed[n.path] = true
    end
  end
  local flattened_comments = flatten_threads_to_comments(vim.tbl_get(node, 'reviewThreads', 'nodes') or {})

  return {
    author = node.author,
    baseRefName = node.baseRefName,
    baseRefOid = node.baseRefOid,
    body = node.body,
    changedFiles = node.changedFiles,
    commits = commits,
    createdAt = node.createdAt,
    headRefName = node.headRefName,
    headRefOid = node.headRefOid,
    isDraft = node.isDraft,
    labels = vim.tbl_get(node, 'labels', 'nodes') or {},
    number = node.number,
    reviewDecision = node.reviewDecision,
    reviews = vim.tbl_get(node, 'reviews', 'nodes') or {},
    title = node.title,
    url = node.url,
    raw_comments = flattened_comments,
    viewed = viewed,
  }
end

--- Builds a `gh` argv with a `--repo <repo>` suffix.
---
--- @param repo string "owner/name". Required; resolve via `M.get_repo` upstream.
--- @param ... string subcommand/args (without the leading "gh").
--- @return string[]
function M.cmd(repo, ...)
  vim.validate('repo', repo, 'string')
  local argv = { 'gh', ... }
  table.insert(argv, '--repo')
  table.insert(argv, repo)
  return argv
end

--- Gets PR data via a single GraphQL query: metadata + comments + per-file "Viewed" state.
---
--- - Drops resolved threads.
--- - Provides a per-comment `outdated` field, so the caller doesn't need to walk the "thread".
--- - Provides a map of  `viewed` files.
--- - Threads and files are limited to 100.
---
--- If `force` is not true, skips the API call and gets data from b:guh on curbuf, else tries
--- the `/pr/…` buffer for the given `(repo, prnum)` key.
---
--- @param prnum string|number PR number.
--- @param repo string "owner/name".
--- @param opts? { force?: boolean }
--- @param cb fun(pr?: PullRequest)
function M.get_pr_data(prnum, repo, opts, cb)
  vim.validate('repo', repo, 'string')
  opts = opts or {}
  if not opts.force then
    local b_guh = vim.b.guh or {}
    if b_guh.pr_data then
      return cb(b_guh.pr_data)
    end
    -- Try to get b:guh.pr_data from the `/pr/…` buffer.
    local pr_buf = state.get_buf('pr', ('%s/%s'):format(repo, prnum), true)
    if pr_buf then
      local pr_data = (vim.b[pr_buf].guh or {}).pr_data
      if pr_data then
        state.set_b_guh(0, { pr_data = pr_data })
        return cb(pr_data)
      end
    end
  end
  local owner, name = repo:match('^([^/]+)/(.+)$')
  if not owner then
    util.log('get_pr_data invalid repo', repo)
    return cb(nil)
  end
  local query = [[
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$number){
          author{login}
          baseRefName baseRefOid
          body
          changedFiles
          commits(first:100){ nodes{ commit{ oid committedDate messageHeadline messageBody } } }
          createdAt
          headRefName headRefOid
          isDraft
          labels(first:20){ nodes{ name } }
          number
          reviewDecision
          reviews(first:20){ nodes{ state body author{login} submittedAt } }
          title
          url
          reviewThreads(first:100){
            nodes{
              isOutdated isResolved
              diffSide
              comments(first:100){
                nodes{
                  databaseId body diffHunk path
                  line originalLine startLine originalStartLine
                  url updatedAt
                  author{login}
                  replyTo{databaseId}
                }
              }
            }
          }
          files(first:100){
            nodes{ path viewerViewedState }
          }
        }
      }
    }
  ]]
  local cmd = {
    'gh',
    'api',
    'graphql',
    '-F',
    'owner=' .. owner,
    '-F',
    'name=' .. name,
    '-F',
    f('number=%d', prnum),
    '-f',
    'query=' .. query,
  }
  local buf = vim.api.nvim_get_current_buf()
  util.system(cmd, function(stdout, stderr, code)
    if code ~= 0 then
      util.log('get_pr_data error', stderr)
      return cb(nil)
    end
    local resp = parse_or_default(stdout, {})
    local node = vim.tbl_get(resp, 'data', 'repository', 'pullRequest')
    if not node then
      util.log('get_pr_data empty', resp)
      return cb(nil)
    end
    local pr = to_pr(node)
    state.set_b_guh(buf, { pr_data = pr })
    util.log('get_pr_data resp', { comments = #pr.raw_comments, viewed = vim.tbl_count(pr.viewed) })
    cb(pr)
  end)
end

function M.get_repo(cb)
  local progress = util.new_progress_report('Loading...', 0)
  progress('running')
  util.system({ 'gh', 'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner' }, function(stdout, _, code)
    if code ~= 0 then
      progress('failed')
    else
      cb(vim.split(stdout, '\n')[1])
      progress('success')
    end
  end)
end

--- @param repo? string "owner/name" for non-local repo.
function M.reply_to_comment(prnum, body, reply_to, repo, cb)
  vim.validate('repo', repo, 'string')
  local request = {
    'gh',
    'api',
    '--method',
    'POST',
    f('repos/%s/pulls/%d/comments', repo, prnum),
    '-f',
    'body=' .. body,
    '-F',
    'in_reply_to=' .. reply_to,
  }
  util.log('reply_to_comment request', request)

  util.system(request, function(result)
    local resp = parse_or_default(result, { errors = {} })

    util.log('reply_to_comment resp', resp)
    cb(resp)
  end)
end

--- @param repo? string "owner/name" for non-local repo.
function M.new_comment(pr, body, path, start_line, line, side, repo, cb)
  local commit_id = assert(pr.headRefOid)
  vim.validate('repo', repo, 'string')

  local request = {
    'gh',
    'api',
    '--method',
    'POST',
    f('repos/%s/pulls/%d/comments', repo, pr.number),
    '-f',
    'body=' .. body,
    '-f',
    'commit_id=' .. commit_id,
    '-f',
    'path=' .. path,
    '-F',
    'line=' .. line,
    '-f',
    'side=' .. (side or 'RIGHT'),
  }

  if start_line ~= line then
    table.insert(request, '-F')
    table.insert(request, 'start_line=' .. start_line)
  end

  util.log('new_comment request', request)

  util.system(request, function(result)
    local resp = parse_or_default(result, { errors = {} })
    util.log('new_comment resp', resp)
    cb(resp)
  end)
end

--- Posts a top-level comment on a PR or issue overview.
---
--- @param kind 'pr'|'issue'
--- @param id integer
--- @param repo string "owner/name"
--- @param body string
--- @param cb fun(ok: boolean, stderr?: string)
function M.new_overview_comment(kind, id, repo, body, cb)
  local request = M.cmd(repo, kind, 'comment', tostring(id), '--body', body)
  util.log('new_overview_comment request', request)
  util.system(request, function(stdout, stderr, code)
    util.log('new_overview_comment resp', { stdout = stdout, stderr = stderr, code = code })
    cb(code == 0, stderr)
  end)
end

--- @param repo? string "owner/name" for non-local repo.
function M.update_comment(comment_id, body, repo, cb)
  vim.validate('repo', repo, 'string')
  local request = {
    'gh',
    'api',
    '--method',
    'PATCH',
    f('repos/%s/pulls/comments/%s', repo, comment_id),
    '-f',
    'body=' .. body,
  }
  util.log('update_comment request', request)

  util.system(request, function(result)
    local resp = parse_or_default(result, { errors = {} })
    util.log('update_comment resp', resp)
    cb(resp)
  end)
end

--- @param repo? string "owner/name" for non-local repo.
function M.delete_comment(comment_id, repo, cb)
  vim.validate('repo', repo, 'string')
  local request = {
    'gh',
    'api',
    '--method',
    'DELETE',
    f('repos/%s/pulls/comments/%s', repo, comment_id),
  }
  util.log('delete_comment request', request)

  util.system(request, function(resp)
    util.log('delete_comment resp', resp)
    cb(resp)
  end)
end

--- Merges a PR via `gh pr merge`.
---
--- @param id integer
--- @param repo string "owner/name"
--- @param method 'merge'|'squash'|'rebase'
--- @param subject? string commit subject (squash/merge only)
--- @param body? string commit body (squash/merge only)
--- @param admin? boolean pass `--admin` to bypass branch protections
--- @param cb fun(ok: boolean, stderr: string)
function M.merge_pr(id, repo, method, subject, body, admin, cb)
  vim.validate('id', id, 'number')
  vim.validate('repo', repo, 'string')
  vim.validate('method', method, function(m)
    return m == 'merge' or m == 'squash' or m == 'rebase'
  end, "'merge'|'squash'|'rebase'")
  vim.validate('subject', subject, 'string', true)
  vim.validate('body', body, 'string', true)
  vim.validate('admin', admin, 'boolean', true)
  local cmd = M.cmd(repo, 'pr', 'merge', tostring(id), '--' .. method)
  if method ~= 'rebase' and subject and subject ~= '' then
    table.insert(cmd, '--subject')
    table.insert(cmd, subject)
    table.insert(cmd, '--body')
    table.insert(cmd, body or '')
  end
  if admin then
    table.insert(cmd, '--admin')
  end
  util.system(cmd, function(_, stderr, code)
    cb(code == 0, stderr or '')
  end)
end

--- Submits a PR review.
--- @param id integer
--- @param repo string "owner/name"
--- @param action 'approve'|'request-changes'|'comment'
--- @param body? string review body (required for `request-changes` and `comment`).
--- @param cb fun(ok: boolean, stderr: string)
function M.review_pr(id, repo, action, body, cb)
  vim.validate('id', id, 'number')
  vim.validate('repo', repo, 'string')
  vim.validate('action', action, function(a)
    return a == 'approve' or a == 'request-changes' or a == 'comment'
  end, "'approve'|'request-changes'|'comment'")
  vim.validate('body', body, 'string', true)
  local flag = action == 'approve' and '--approve' or action == 'request-changes' and '--request-changes' or '--comment'
  local cmd = M.cmd(repo, 'pr', 'review', tostring(id), flag)
  if body and body ~= '' then
    table.insert(cmd, '--body')
    table.insert(cmd, body)
  end
  util.system(cmd, function(_, stderr, code)
    cb(code == 0, stderr or '')
  end)
end

function M.get_user(cb)
  util.system({ 'gh', 'api', 'user', '-q', '.login' }, function(stdout, _, code)
    if code == 0 then
      cb(vim.split(stdout, '\n')[1])
    end
  end)
end

--- Gets metadata for the most-recent matrix-expanded CI jobs at the PR's head commit.
--- Dedupes by job name, keeping the latest `startedAt`.
---
--- @param pr PullRequest
--- @param repo? string "owner/name" for non-local repo.
--- @param cb fun(jobs?: { databaseId: integer, name: string, conclusion: string, status: string, startedAt: string, url: string }[], error?: string)
function M.get_pr_ci_jobs_logs(pr, repo, cb)
  local head_sha = pr.headRefOid
  if util.is_empty(head_sha) then
    cb(nil, f('PR #%s has no head commit SHA', pr.number))
    return
  end

  local progress = util.new_progress_report('Loading CI jobs', 0)
  progress('running', nil, 'fetching check-runs')

  vim.validate('repo', repo, 'string')
  -- `--paginate` is safe here: `filter=latest` collapses re-runs server-side, so the count is bounded by distinct check
  -- names for this one commit (matrix-expanded across workflow files): so this usually fetches only 1 page (<100 items).
  util.system({
    'gh',
    'api',
    '--paginate',
    '--slurp',
    f('repos/%s/commits/%s/check-runs?filter=latest&per_page=100', repo, head_sha),
  }, function(result, stderr, code)
    if code ~= 0 then
      progress('failed')
      cb(nil, ('gh api check-runs failed: %s'):format(vim.trim(stderr or '')))
      return
    end

    local pages = parse_or_default(result, {})
    local by_name = {}
    for _, page in ipairs(pages) do
      for _, cr in ipairs(page.check_runs or {}) do
        if cr.app and cr.app.slug == 'github-actions' then
          -- details_url: https://github.com/{owner}/{repo}/actions/runs/{run_id}/job/{job_id}
          local job_id = tonumber((cr.details_url or ''):match('/job/(%d+)'))
          if job_id then
            -- `filter=latest` already returns one per name; the timestamp comparison is just defensive.
            local existing = by_name[cr.name]
            if not existing or (cr.started_at or '') > (existing.startedAt or '') then
              by_name[cr.name] = {
                databaseId = job_id,
                name = cr.name,
                conclusion = cr.conclusion,
                status = cr.status,
                startedAt = cr.started_at,
                url = cr.html_url,
              }
            end
          end
        end
      end
    end

    local jobs = {}
    for _, job in pairs(by_name) do
      table.insert(jobs, job)
    end
    if #jobs == 0 then
      progress('failed')
      cb(nil, f('No GitHub Actions jobs for PR #%s at %s', pr.number, head_sha))
      return
    end

    -- Sort by (status, name).
    table.sort(jobs, function(a, b)
      local a_status = a.conclusion or a.status or '?'
      local b_status = b.conclusion or b.status or '?'
      if a_status ~= b_status then
        return a_status < b_status
      end
      return (a.name or '') < (b.name or '')
    end)
    progress('success')
    cb(jobs)
  end)
end

--- Fetches the log for a single workflow job.
---
--- @param job_id integer Workflow job ID (e.g. `job.databaseId` from `get_pr_ci_jobs_logs`).
--- @param repo? string "owner/name" for non-local repo.
--- @param cb fun(log?: string, error?: string)
function M.get_pr_ci_logs(job_id, repo, cb)
  local progress = util.new_progress_report('Loading CI log', 0)
  progress('running', nil, 'job %s', tostring(job_id))

  vim.validate('repo', repo, 'string')
  -- Use the raw REST endpoint instead of `gh run view --log` to avoid gh's "{workflow} / {job} {step}" prefix.
  util.system({
    'gh',
    'api',
    f('repos/%s/actions/jobs/%s/logs', repo, tostring(job_id)),
  }, function(logs, stderr, code)
    if code ~= 0 or util.is_empty(vim.trim(logs or '')) then
      progress('failed')
      cb(nil, ('Log unavailable: %s'):format(vim.trim(stderr or '')))
      return
    end
    -- Strip the leading UTF-8 BOM that the REST API prepends to log payloads.
    logs = logs:gsub('^\xef\xbb\xbf', '')
    progress('success')
    cb(vim.trim(logs))
  end)
end

return M
