local state = require('guh.state')
local util = require('guh.util')

require('guh.types')

local f = string.format

local M = {}

--- Last-seen rate-limit status. Updated by `M.check_rate_limit` (explicit poll) and
--- `M.note_rate_limit` (passive detection from gh stderr).
---
--- Inspect interactively: `:lua = require('guh.gh').rate_limit`
--- @type { limited: boolean, kind?: 'primary'|'secondary', checked_at?: integer, core?: table, message?: string }
M.rate_limit = { limited = false }

-- PR-state highlights. Open=green, Closed=red, Merged=blue (Draft falls through to default).
M.state_hl = { Open = 'OkMsg', Closed = 'ErrorMsg', Merged = 'DiagnosticHint' }

-- GraphQL `reactionGroups[].content` → emoji.
M.reaction_emoji = {
  THUMBS_UP = '👍',
  THUMBS_DOWN = '👎',
  LAUGH = '😄',
  HOORAY = '🎉',
  CONFUSED = '😕',
  HEART = '❤️',
  ROCKET = '🚀',
  EYES = '👀',
}

--- "Open" | "Draft" | "Closed" | "Merged" | "?".
--- @param pr PullRequest
function M.pr_state_label(pr)
  return pr.isDraft and 'Draft' or (pr.state and (pr.state:sub(1, 1) .. pr.state:sub(2):lower()) or '?')
end

--- Status emoji for a CI job.
--- @param job CIJob
function M.ci_icon(job)
  if not job.conclusion then
    return '⏳' -- No `conclusion` until job finishes (still-running / in-progress).
  elseif job.conclusion == 'success' or job.conclusion == 'neutral' or job.conclusion == 'skipped' then
    return '✅'
  end
  return '❌'
end

--- Gets the github.com web URL for a `guh://` buffer, or nil.
---
--- @param buf integer Buffer id (0 for current buffer).
--- @return string?
function M.get_url(buf)
  local b = state.get_b_guh(buf) or {}
  if b.feat == 'status' then
    return 'https://github.com/notifications'
  end
  if not b.repo then
    return nil
  end
  local base = 'https://github.com/' .. b.repo
  if b.feat == 'repo' then
    return base
  elseif b.feat == 'issue' then
    return ('%s/issues/%s'):format(base, b.id)
  elseif b.feat == 'commit' then
    return ('%s/commit/%s'):format(base, b.id)
  elseif b.feat == 'prdiff' then
    return ('%s/pull/%s/changes'):format(base, b.id)
  elseif b.feat == 'pr' or b.feat == 'prcomments' or b.feat == 'prlogs' or b.feat == 'file' then
    return ('%s/pull/%s'):format(base, b.id)
  end
  return nil
end

local function parse_or_default(str, default)
  local success, result = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
  if success then
    return result
  end

  return default
end

--- Scans gh stderr for known rate-limit error strings. Updates `M.rate_limit` if matched.
--- Safe to call on every gh call.
---
--- @param stderr string
--- @param code integer gh exit code
function M.note_rate_limit(stderr, code)
  if code == 0 or not stderr or stderr == '' then
    return
  end
  local kind = (stderr:match('secondary rate limit') or stderr:match('abuse detection')) and 'secondary'
    or (stderr:match('API rate limit exceeded') or stderr:match('rate limit exceeded')) and 'primary'
    or nil

  if kind then
    M.rate_limit = {
      limited = true,
      kind = kind,
      checked_at = vim.uv.now(),
      message = vim.trim(stderr),
    }
  end
end

--- Polls `gh api rate_limit` (the rate-limit endpoint is itself "free") and updates `M.rate_limit`.
--- Use this to actively check; passive detection only fires on failures.
---
--- @param on_done? fun(rate_limit: table)
function M.check_rate_limit(on_done)
  util.system({ 'gh', 'api', 'rate_limit' }, nil, function(r)
    if r.code == 0 then
      local core = vim.tbl_get(parse_or_default(r.stdout, {}), 'resources', 'core')
      M.rate_limit = {
        limited = core and core.remaining == 0 or false,
        kind = 'primary',
        checked_at = vim.uv.now(),
        core = core,
      }
    end -- else: `note_rate_limit` was already invoked by `util.system` on failure.
    if on_done then
      on_done(M.rate_limit)
    end
  end)
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
      -- Thread-level: head comment anchors to current-HEAD. Decides "outside" vs "outdated" (no HEAD line).
      local in_head = (nodes[1] and nodes[1].line) ~= nil
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
            in_head = in_head,
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
--- Dedupes by name ("workflow: job-name", latest `startedAt`), drops `skipped`, sorts by (status, name).
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
      local workflow = vim.tbl_get(cr, 'checkSuite', 'workflowRun', 'workflow', 'name')
      -- Name = "<workflow>: <job>". Affects dedupe + sorting.
      local name = workflow and ('%s: %s'):format(workflow, cr.name) or cr.name
      local existing = by_name[name]
      if not existing or (cr.startedAt or '') > (existing.startedAt or '') then
        by_name[name] = {
          databaseId = job_id,
          runId = run_id,
          name = name,
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
  local viewed = vim.empty_dict()
  local file_paths = vim.empty_dict() ---@type table<string,true>   -- All current paths in this PR.
  for _, n in ipairs(vim.tbl_get(node, 'files', 'nodes') or {}) do
    file_paths[n.path] = true
    if n.viewerViewedState == 'VIEWED' then
      viewed[n.path] = true
    end
  end
  local flattened_comments, n_threads, n_resolved =
    flatten_threads_to_comments(vim.tbl_get(node, 'reviewThreads', 'nodes') or {})

  return {
    node_id = node.id,
    additions = node.additions,
    author = node.author,
    authorAssociation = node.authorAssociation,
    baseRefName = node.baseRefName,
    baseRefOid = node.baseRefOid,
    body = node.body,
    changedFiles = node.changedFiles,
    ci_jobs = to_ci_jobs(node),
    commits = commits,
    createdAt = node.createdAt,
    deletions = node.deletions,
    headRefName = node.headRefName,
    headRefOid = node.headRefOid,
    isDraft = node.isDraft,
    labels = vim.tbl_get(node, 'labels', 'nodes') or {},
    number = node.number,
    reactions = node.reactionGroups or {},
    reviewDecision = node.reviewDecision,
    reviews = vim.tbl_get(node, 'reviews', 'nodes') or {},
    state = node.state,
    title = node.title,
    url = node.url,
    raw_comments = flattened_comments,
    viewed = viewed,
    file_paths = file_paths,
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
--- @param on_result fun(pr?: PullRequest, err?: string) `err` = error message when `pr` is nil.
function M.get_pr_data(prnum, repo, opts, on_result)
  vim.validate('repo', repo, 'string')
  opts = opts or {}
  if not opts.force then
    local pr_data = state.get_pr_data(repo, prnum)
    if pr_data then
      return on_result(pr_data)
    end
  end
  local owner, name = repo:match('^([^/]+)/(.+)$')
  if not owner then
    util.log('get_pr_data invalid repo', repo)
    return on_result(nil)
  end
  local query = [[
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        defaultBranchRef{ name }
        pullRequest(number:$number){
          id
          author{login ... on User{name}}
          authorAssociation
          additions deletions
          baseRefName baseRefOid
          body
          changedFiles
          state
          reactionGroups{ content reactors{ totalCount } }
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
                      checkSuite{ app{ slug } workflowRun{ workflow{ name } } }
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
  util.system(cmd, nil, function(r)
    if r.code ~= 0 then
      util.log('get_pr_data error', r.stderr)
      return on_result(nil, ('Failed to fetch PR #%s: %s'):format(prnum, vim.trim(r.stderr or '')))
    end
    local resp = parse_or_default(r.stdout, {})
    -- GraphQL can return HTTP 200 with an `errors` array (e.g. invalid field) and no `data`.
    if resp.errors then
      util.log('get_pr_data graphql errors', resp.errors)
      return on_result(nil, ('Failed to fetch PR #%s: %s'):format(prnum, table.concat(util.gh_errors(resp), '; ')))
    end
    local node = vim.tbl_get(resp, 'data', 'repository', 'pullRequest')
    if not node then
      util.log('get_pr_data empty', resp)
      return on_result(nil, ('PR #%s not found in repo "%s"'):format(prnum, repo))
    end
    local pr = to_pr(node)
    pr.defaultBranch = vim.tbl_get(resp, 'data', 'repository', 'defaultBranchRef', 'name')
    -- Cache on the `pr/…` buffer only (single-source-of-truth). Create it if needed.
    state.set_b_key(assert(state.get_buf('pr', repo, prnum)), { 'guh', 'pr_data' }, pr)
    util.log('get_pr_data resp', { comments = #pr.raw_comments, viewed = vim.tbl_count(pr.viewed) })
    on_result(pr)
  end)
end

--- @param cwd? string Directory to resolve the repo from (default: nvim CWD).
--- @param on_done fun(repo?: string)
function M.get_repo(cwd, on_done)
  local progress = util.new_progress_report('Loading...', 0)
  progress('running')
  util.system({ 'gh', 'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner' }, { cwd = cwd }, function(r)
    local repo = r.code == 0 and vim.trim(r.stdout or '') or ''
    if repo == '' then
      progress('failed')
      on_done(nil)
    else
      progress('success')
      on_done(repo)
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
  util.system(request, nil, function(r)
    local resp = parse_or_default(r.stdout, { errors = {} })
    util.log(logname .. ' resp', resp)
    cb(resp)
  end)
end

--- Fetches the user's "Unread" notifications, and stores their thread-ids in the `b:guh.notifications`
--- map (for mark-as-read/done and opportunistic probe-skip), and returns the rendered lines.
---
--- @param buf integer The `guh://status` buffer.
--- @param on_done fun(lines?: string[], err?: string)
function M.get_user_notifs(buf, on_done)
  gh_api('get_user_notifs', 'GET', 'notifications', {}, function(r)
    if r.errors then
      local errs = util.gh_errors(r)
      return on_done(nil, #errs > 0 and table.concat(errs, '; ') or 'Failed to fetch notifications')
    end
    local map = vim.empty_dict() ---@type table<string, Notification> slug ("owner/repo#NNN") => Notification.
    local groups = {} ---@type table<string, string[]> repo => display lines (in original/chronological order).
    local repos = {} ---@type string[] repo names.
    for _, n in ipairs(r) do
      local typ = n.subject and n.subject.type
      if typ == 'Issue' or typ == 'PullRequest' then
        local repo = n.repository.full_name
        -- `owner/repo#NNN` is a slug that ":Guh ." can open.
        local slug = ('%s#%s'):format(repo, (n.subject.url or ''):match('(%d+)$'))
        map[slug] = { thread_id = n.id, is_pr = typ == 'PullRequest' }
        if not groups[repo] then
          groups[repo] = {}
          table.insert(repos, repo)
        end
        table.insert(groups[repo], ('  %s  %s'):format(slug, n.subject.title))
      end
    end
    table.sort(repos) -- Sort groups by repo-name; items within a group keep their original order.
    local lines = { 'Notifications (unread):' }
    for _, repo in ipairs(repos) do
      vim.list_extend(lines, groups[repo])
      table.insert(lines, '')
    end
    if vim.api.nvim_buf_is_valid(buf) then
      state.set_b_key(buf, { 'guh', 'notifications' }, map)
    end
    on_done(lines)
  end)
end

--- Marks a notification thread as read. (One-way: GitHub's REST API has no "mark as UNread".)
---
--- @param thread_id string|integer Notification thread-id (`b:guh.notifications[slug].thread_id`).
--- @param on_done fun(ok: boolean, err?: string)
function M.set_notif_read(thread_id, on_done)
  -- Note: gh_api() checks `resp.errors`, but this endpoint returns an empty 205.
  util.system({ 'gh', 'api', '--method', 'PATCH', f('notifications/threads/%s', thread_id) }, nil, function(r)
    on_done(r.code == 0, r.code ~= 0 and vim.trim(r.stderr or '') or nil)
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
    -- Multiline: `start_side` must match `side`.
    table.insert(fields, { '-f', 'start_side=' .. (side or 'RIGHT') })
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
  util.system(request, nil, function(r)
    util.log('new_top_comment resp', { stdout = r.stdout, stderr = r.stderr, code = r.code })
    cb(r.code == 0, r.stderr)
  end)
end

--- @param repo string "owner/repo"
function M.update_comment(comment_id, body, repo, cb)
  vim.validate('repo', repo, 'string')
  gh_api('update_comment', 'PATCH', f('repos/%s/pulls/comments/%s', repo, comment_id), {
    { '-f', 'body=' .. body },
  }, cb)
end

--- Deletes a PR review comment.
---
--- @param repo string "owner/repo"
--- @param on_done fun(ok: boolean, err?: string)
function M.delete_comment(comment_id, repo, on_done)
  vim.validate('repo', repo, 'string')
  -- Note: gh_api() checks `resp.errors`, but this endpoint returns an empty 204.
  util.system({ 'gh', 'api', '--method', 'DELETE', f('repos/%s/pulls/comments/%s', repo, comment_id) }, nil, function(r)
    on_done(r.code == 0, r.code ~= 0 and vim.trim(r.stderr or '') or nil)
  end)
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

--- Marks a file as "Viewed"/"Unviewed" for the current user on a PR.
---
--- @param pr_node_id string PR's GraphQL node ID (`pr_data.node_id`).
--- @param path string File path.
--- @param viewed boolean Mark as "Viewed"
--- @param on_done fun(resp: table)
function M.set_file_viewed(pr_node_id, path, viewed, on_done)
  vim.validate('pr_node_id', pr_node_id, 'string')
  vim.validate('path', path, 'string')
  local op = viewed and 'markFileAsViewed' or 'unmarkFileAsViewed'
  local query = ([[
    mutation($pr:ID!, $path:String!){
      %s(input:{pullRequestId:$pr, path:$path}){ pullRequest{ id } }
    }
  ]]):format(op)
  gh_api('set_file_viewed', 'POST', 'graphql', {
    { '-F', 'pr=' .. pr_node_id },
    { '-F', 'path=' .. path },
    { '-f', 'query=' .. query },
  }, on_done)
end

--- Sets the PR "Draft"/"Ready" state.
---
--- @param id integer
--- @param repo string "owner/name"
--- @param draft boolean true: convert to draft; false: mark ready for review.
--- @param cb fun(ok: boolean, stderr: string)
function M.set_pr_draft(id, repo, draft, cb)
  local cmd = M.cmd(repo, 'pr', 'ready', tostring(id))
  if draft then
    table.insert(cmd, '--undo')
  end
  util.system(cmd, nil, function(r)
    cb(r.code == 0, r.stderr or '')
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
  util.system(cmd, nil, function(r)
    cb(r.code == 0, r.stderr or '')
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
  util.system(cmd, nil, function(r)
    cb(r.code == 0, r.stderr or '')
  end)
end

local cached_user --[[@type string?]]
--- Gets the active `gh` username from local config. Synchronous; cached for the session.
---
--- (Works without network, but cached because `gh` may try the network anyway.)
---
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
  util.system(cmd, nil, function(r)
    on_response(r.code == 0, r.stderr or '')
  end)
end

--- Fetches the log for one CI workflow job.
---
--- @param job_id integer Workflow job ID (`pr_data.ci_jobs[i].databaseId`).
--- @param repo string "owner/repo"
--- @param on_result fun(log?: string, error?: string)
function M.get_pr_ci_log(job_id, repo, on_result)
  local progress = util.new_progress_report('Loading CI log', 0)
  progress('running', nil, 'job %s', tostring(job_id))

  vim.validate('repo', repo, 'string')
  -- Use the raw REST endpoint instead of `gh run view --log` to avoid gh's "{workflow} / {job} {step}" prefix.
  util.system(
    {
      'gh',
      'api',
      f('repos/%s/actions/jobs/%s/logs', repo, tostring(job_id)),
    },
    nil,
    function(r)
      if r.code ~= 0 or util.is_empty(vim.trim(r.stdout or '')) then
        progress('failed')
        on_result(nil, ('Log unavailable: %s'):format(vim.trim(r.stderr or '')))
        return
      end
      -- Strip the leading UTF-8 BOM that the REST API prepends to log payloads.
      local logs = r.stdout:gsub('^\xef\xbb\xbf', '')
      progress('success')
      on_result(vim.trim(logs))
    end
  )
end

--- Concurrently fetches CI logs for the given `jobs`. Invokes `on_result()` in completion order.
--- Skips jobs for which `skip(job)` returns true (e.g. already populated buf).
---
--- @param jobs CIJob[]
--- @param repo string "owner/repo"
--- @param skip? fun(job: CIJob): boolean
--- @param on_result fun(job: CIJob, log?: string, err?: string)
function M.get_pr_ci_logs(jobs, repo, skip, on_result)
  vim.validate('repo', repo, 'string')
  for _, job in ipairs(jobs) do
    if not (skip and skip(job)) then
      M.get_pr_ci_log(job.databaseId, repo, function(log, err)
        on_result(job, log, err)
      end)
    end
  end
end

M._to_ci_jobs = to_ci_jobs -- testing

return M
