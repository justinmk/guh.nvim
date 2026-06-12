local state = require('guh.state')
local util = require('guh.util')

require('guh.types')

local f = string.format

local M = {}

local function parse_or_default(str, default)
  local success, result = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
  if success then
    return result
  end

  return default
end

--- Takes nested threads (GraphQL: `reviewThreads.nodes`) and produces a flat list of comments.
---
--- @return Comment[] comments
--- @return integer n_threads total thread count
--- @return integer n_resolved resolved thread count
local function flatten_threads_to_comments(threads)
  local out = {}
  local n_resolved = 0
  for _, thread in ipairs(threads or {}) do
    if thread.isResolved then
      -- Drop resolved threads entirely.
      n_resolved = n_resolved + 1
    else
      local nodes = vim.tbl_get(thread, 'comments', 'nodes') or {}
      local thread_id = nodes[1] and nodes[1].databaseId
      -- GraphQL global node id (e.g. "PRRT_kw…"). Needed by the resolveReviewThread mutation.
      local thread_node_id = thread.id
      -- Reply comments on outdated threads carry no originalLine of their own;
      -- inherit from the head comment so they aren't filtered out below.
      local head_line = nodes[1] and nodes[1].originalLine
      local head_start = nodes[1] and nodes[1].originalStartLine
      local head_path = nodes[1] and nodes[1].path
      -- `diffSide` is a thread-level property in GraphQL; every comment in the thread inherits it.
      local c_side = thread.diffSide
      for _, c in ipairs(nodes) do
        local c_path = c.path ~= nil and c.path or head_path
        -- LEFT-side (deleted-line) comments, and outdated threads, have a null `line` on HEAD; fallback to `originalLine` then.
        local effective_end_line = c.line ~= nil and c.line or c.originalLine ~= nil and c.originalLine or head_line
        local effective_start = c.startLine ~= nil and c.startLine
          or c.originalStartLine ~= nil and c.originalStartLine
          or head_start
        if effective_end_line ~= nil and c_path ~= nil then
          local reply_to
          if c.replyTo ~= nil and c.replyTo.databaseId then
            reply_to = c.replyTo.databaseId
          end
          table.insert(out, {
            id = c.databaseId,
            html_url = c.url,
            user = { login = c.author ~= nil and c.author.login or '?' },
            body = c.body or '',
            diff_hunk = c.diffHunk or '',
            path = c_path,
            end_line = effective_end_line,
            start_line = effective_start,
            side = c_side,
            updated_at = c.updatedAt,
            in_reply_to_id = reply_to,
            outdated = thread.isOutdated or false,
            thread_id = thread_id,
            thread_node_id = thread_node_id,
          })
        end
      end
    end
  end
  return out, #(threads or {}), n_resolved
end

--- Extracts CI jobs (github-actions check-runs) from the HEAD commit `statusCheckRollup`.
--- Dedupes by name (latest `startedAt`), drops `skipped`, sorts by (status, name).
---
--- @return CIJob[]
local function to_ci_jobs(node)
  local rollup_commits = vim.tbl_get(node, 'headCommit', 'nodes') or {}
  local contexts = vim.tbl_get(rollup_commits[1] or {}, 'commit', 'statusCheckRollup', 'contexts', 'nodes') or {}
  local by_name = {}
  for _, cr in ipairs(contexts) do
    -- Only `CheckRun` from the `github-actions` app has a fetchable workflow log.
    local is_actions = cr.__typename == 'CheckRun' and vim.tbl_get(cr, 'checkSuite', 'app', 'slug') == 'github-actions'
    -- detailsUrl: https://github.com/{owner}/{repo}/actions/runs/{run_id}/job/{job_id}
    local url = (is_actions and cr.detailsUrl) or ''
    local run_id, job_id = url:match('/actions/runs/(%d+)/job/(%d+)')
    run_id = tonumber(run_id)
    job_id = tonumber(job_id)
    if job_id and cr.conclusion ~= 'SKIPPED' then
      local existing = by_name[cr.name]
      if not existing or (cr.startedAt or '') > (existing.startedAt or '') then
        by_name[cr.name] = {
          databaseId = job_id,
          runId = run_id,
          name = cr.name,
          -- Mimic the REST API which returns lowercase ("success", "failure", …).
          conclusion = cr.conclusion and cr.conclusion:lower() or nil,
          status = cr.status and cr.status:lower() or nil,
          startedAt = cr.startedAt,
          url = cr.detailsUrl,
        }
      end
    end
  end
  local jobs = {}
  for _, j in pairs(by_name) do
    table.insert(jobs, j)
  end
  table.sort(jobs, function(a, b)
    local a_s = a.conclusion or a.status or '?'
    local b_s = b.conclusion or b.status or '?'
    if a_s ~= b_s then
      return a_s < b_s
    end
    return (a.name or '') < (b.name or '')
  end)
  return jobs
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
  local flattened_comments, n_threads, n_resolved =
    flatten_threads_to_comments(vim.tbl_get(node, 'reviewThreads', 'nodes') or {})

  return {
    author = node.author,
    baseRefName = node.baseRefName,
    baseRefOid = node.baseRefOid,
    body = node.body,
    changedFiles = node.changedFiles,
    ci_jobs = to_ci_jobs(node),
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
    n_threads = n_threads,
    n_resolved = n_resolved,
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
--- If `opts.force` is true, skips the API call and gets data from b:guh on curbuf, else tries
--- the `/pr/…` buffer for the given `(repo, prnum)` key.
---
--- Note: The cache lives on the `pr/…` buffer (single-source-of-truth).
---
--- @param prnum string|integer PR number.
--- @param repo string "owner/name".
--- @param opts? { force?: boolean }
--- @param cb fun(pr?: PullRequest)
function M.get_pr_data(prnum, repo, opts, cb)
  vim.validate('repo', repo, 'string')
  opts = opts or {}
  if not opts.force then
    local pr_data = state.get_pr_data(repo, prnum)
    if pr_data then
      return cb(pr_data)
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
              id
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
          headCommit:commits(last:1){
            nodes{ commit{
              # CI jobs at the HEAD commit; extracted by `to_ci_jobs`.
              statusCheckRollup{
                contexts(first:100){
                  nodes{
                    __typename
                    ... on CheckRun{
                      databaseId name conclusion status startedAt detailsUrl
                      checkSuite{ app{ slug } }
                    }
                  }
                }
              }
            }}
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
    -- Cache on the `pr/…` buffer only (single-source-of-truth). Create it if needed.
    state.set_b_guh(assert(state.get_buf('pr', repo, prnum)), { pr_data = pr })
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

--- Runs `gh api --method <method> <endpoint>` with `fields` of the form `{ {'-f','key=val'}, {'-F','key=val'}, … }`.
---
--- Logs request + response and invokes `cb()` with the JSON-decoded body (or `{ errors = {} }` on parse failure).
---
--- @param logname string for `util.log` (usually the caller name).
--- @param method 'POST'|'PATCH'|'DELETE'|'GET'|'PUT'
--- @param endpoint string e.g. "repos/foo/bar/pulls/1/comments".
--- @param fields { [1]: '-f'|'-F', [2]: string }[]
--- @param cb fun(resp: table)
local function gh_api(logname, method, endpoint, fields, cb)
  local request = { 'gh', 'api', '--method', method, endpoint }
  for _, kv in ipairs(fields) do
    table.insert(request, kv[1])
    table.insert(request, kv[2])
  end
  util.log(logname .. ' request', request)
  util.system(request, function(stdout)
    local resp = parse_or_default(stdout, { errors = {} })
    util.log(logname .. ' resp', resp)
    cb(resp)
  end)
end

--- Note: The REST API takes a comment-id, not a thread-id. Any comment in the thread works.
---
--- @param repo string "owner/repo"
function M.reply_to_comment(prnum, body, reply_to, repo, cb)
  vim.validate('repo', repo, 'string')
  gh_api('reply_to_comment', 'POST', f('repos/%s/pulls/%d/comments', repo, prnum), {
    { '-f', 'body=' .. body },
    { '-F', 'in_reply_to=' .. reply_to },
  }, cb)
end

--- @param repo string "owner/repo"
function M.new_comment(pr, body, path, start_line, line, side, repo, cb)
  local commit_id = assert(pr.headRefOid)
  vim.validate('repo', repo, 'string')
  local fields = {
    { '-f', 'body=' .. body },
    { '-f', 'commit_id=' .. commit_id },
    { '-f', 'path=' .. path },
    { '-F', 'line=' .. line },
    { '-f', 'side=' .. (side or 'RIGHT') },
  }
  if start_line ~= line then
    table.insert(fields, { '-F', 'start_line=' .. start_line })
  end
  gh_api('new_comment', 'POST', f('repos/%s/pulls/%d/comments', repo, pr.number), fields, cb)
end

--- Posts a top-level comment on a PR or issue overview.
---
--- @param kind 'pr'|'issue'
--- @param id integer
--- @param repo string "owner/name"
--- @param body string
--- @param cb fun(ok: boolean, stderr?: string)
function M.new_top_comment(kind, id, repo, body, cb)
  local request = M.cmd(repo, kind, 'comment', tostring(id), '--body', body)
  util.log('new_top_comment request', request)
  util.system(request, function(stdout, stderr, code)
    util.log('new_top_comment resp', { stdout = stdout, stderr = stderr, code = code })
    cb(code == 0, stderr)
  end)
end

--- @param repo string "owner/repo"
function M.update_comment(comment_id, body, repo, cb)
  vim.validate('repo', repo, 'string')
  gh_api('update_comment', 'PATCH', f('repos/%s/pulls/comments/%s', repo, comment_id), {
    { '-f', 'body=' .. body },
  }, cb)
end

--- @param repo string "owner/repo"
function M.delete_comment(comment_id, repo, cb)
  vim.validate('repo', repo, 'string')
  gh_api('delete_comment', 'DELETE', f('repos/%s/pulls/comments/%s', repo, comment_id), {}, cb)
end

--- Resolves a review comment-thread.
---
--- Note: `thread_node_id` is the GraphQL global node id (e.g. `PRRT_kw…`), not the REST
--- `databaseId`.
---
--- @param thread_node_id string
--- @param cb fun(resp: table)
function M.resolve_thread(thread_node_id, cb)
  vim.validate('thread_node_id', thread_node_id, 'string')
  local query = [[
    mutation($thread:ID!){
      resolveReviewThread(input:{threadId:$thread}){
        thread{ id isResolved }
      }
    }
  ]]
  gh_api('resolve_thread', 'POST', 'graphql', {
    { '-F', 'thread=' .. thread_node_id },
    { '-f', 'query=' .. query },
  }, cb)
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

local cached_user --[[@type string?]]
--- Gets the active `gh` username from local config. Synchronous; cached for the session.
---
--- (Works without network, but cached because `gh` may try the network anyway.)

--- @return string? user
function M.get_user()
  if cached_user then
    return cached_user
  end
  local jq = '.hosts | to_entries[] | .value[] | select(.active) | .login'
  local r = vim.system({ 'gh', 'auth', 'status', '--active', '--json', 'hosts', '--jq', jq }):wait()
  -- XXX: `gh auth status --json` exits 0 even when not logged in; stdout is empty then.
  if r.code == 0 and vim.trim(r.stdout) ~= '' then
    cached_user = vim.trim(r.stdout)
  end
  return cached_user
end

--- Reruns failed CI jobs for a run, or one specific CI job.
---
--- @param run_id integer GitHub Actions run id.
--- @param repo string "owner/name"
--- @param job_id? integer Workflow job ID (`pr_data.ci_jobs[i].databaseId`).
--- @param on_response fun(ok: boolean, stderr: string)
function M.rerun_ci(run_id, repo, job_id, on_response)
  vim.validate('run_id', run_id, 'number')
  vim.validate('repo', repo, 'string')
  vim.validate('job_id', job_id, 'number', true)
  local cmd = M.cmd(repo, 'run', 'rerun', tostring(run_id))
  if job_id then
    table.insert(cmd, '--job')
    table.insert(cmd, tostring(job_id))
  else
    table.insert(cmd, '--failed')
  end
  util.system(cmd, function(_, stderr, code)
    on_response(code == 0, stderr or '')
  end)
end

--- Fetches the log for one CI workflow job.
---
--- @param job_id integer Workflow job ID (`pr_data.ci_jobs[i].databaseId`).
--- @param repo string "owner/repo"
--- @param cb fun(log?: string, error?: string)
function M.get_pr_ci_log(job_id, repo, cb)
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

--- Concurrently fetches CI logs for the given `jobs`. Invokes `on_result()` in completion order.
--- Skips jobs for which `skip(job)` returns true (e.g. already populated buf).
---
--- @param jobs CIJob[]
--- @param repo string "owner/repo"
--- @param on_result fun(job: CIJob, log?: string, err?: string)
--- @param skip? fun(job: CIJob): boolean
function M.get_pr_ci_logs(jobs, repo, on_result, skip)
  vim.validate('repo', repo, 'string')
  for _, job in ipairs(jobs) do
    if not (skip and skip(job)) then
      M.get_pr_ci_log(job.databaseId, repo, function(log, err)
        on_result(job, log, err)
      end)
    end
  end
end

return M
