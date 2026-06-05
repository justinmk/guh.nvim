local state = require('guh.state')
local util = require('guh.util')

require('guh.types')

local f = string.format

local M = {}

local pr_fields = {
  'author',
  'baseRefName',
  'baseRefOid',
  'body',
  'changedFiles',
  'comments',
  'commits',
  'createdAt',
  'headRefName',
  'headRefOid',
  'isDraft',
  'labels',
  'number',
  'reviewDecision',
  'reviews',
  'title',
  'url',
}

local issue_fields = {
  'author',
  'body',
  'createdAt',
  'labels',
  'number',
  'state',
  'title',
  'updatedAt',
  'url',
}

local function parse_or_default(str, default)
  local success, result = pcall(vim.json.decode, str)
  if success then
    return result
  end

  return default
end

--- Gets details for one "thing" from `gh` and parses the JSON response into an object.
---
--- @param cmd string[] gh command
--- @param b_field string b:guh field to check for (and store) cached data.
local function get_info(cmd, b_field, cb)
  -- Use b:guh cache on the current buffer, if available.
  local b_guh = vim.b.guh
  if b_guh and b_guh[b_field] then
    cb(b_guh[b_field])
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  util.system(cmd, function(result, stderr, code)
    if code ~= 0 then
      if stderr and stderr:match('Unknown JSON field') then
        error(('Unknown JSON field: %s'):format(stderr))
      end
      util.log('get_info error', stderr)
      cb(nil)
      return
    end
    util.log('get_info resp', result)

    local r = parse_or_default(result, nil)
    state.set_b_guh(buf, { [b_field] = r })
    cb(r)
  end)
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

--- Gets PR data from b:guh, or requests it from the API.
---
--- @param prnum string|number PR number, or empty for "current PR"
--- @param repo string "owner/name".
--- @param cb fun(pr?: PullRequest)
function M.get_pr_info(prnum, repo, cb)
  get_info(M.cmd(repo, 'pr', 'view', tostring(prnum), '--json', table.concat(pr_fields, ',')), 'pr_data', cb)
end

--- @param issue_num string|number Issue number
--- @param repo string "owner/name".
--- @param cb fun(issue?: Issue)
function M.get_issue(issue_num, repo, cb)
  get_info(
    M.cmd(repo, 'issue', 'view', tostring(issue_num), '--json', table.concat(issue_fields, ',')),
    'issue_data',
    cb
  )
end

function M.get_repo(cb)
  local progress = util.new_progress_report('Loading...', 0)
  progress('running')
  util.system_str('gh repo view --json nameWithOwner -q .nameWithOwner', function(result)
    if result == nil then
      progress('failed')
    else
      cb(vim.split(result, '\n')[1])
      progress('success')
    end
  end)
end

--- Fetches review comments via the GraphQL `reviewThreads` API so we get per-thread `isOutdated` / `isResolved`. Drops
--- resolved threads; flags each comment with its thread's `outdated` so the caller can handle outdated threads.
---
--- @param id integer
--- @param repo string "owner/name"
--- @param cb fun(comments: table[])
function M.load_comments(id, repo, cb)
  assert(cb)
  vim.validate('repo', repo, 'string')
  local owner, name = repo:match('^([^/]+)/(.+)$')
  if not owner then
    util.log('load_comments invalid repo', repo)
    cb({})
    return
  end
  local query = [[
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$number){
          reviewThreads(first:100){
            nodes{
              isOutdated isResolved
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
    f('number=%d', id),
    '-f',
    'query=' .. query,
  }
  util.system(cmd, function(stdout, stderr, code)
    if code ~= 0 then
      util.log('load_comments error', stderr)
      cb({})
      return
    end
    local resp = parse_or_default(stdout, {})
    local threads = vim.tbl_get(resp, 'data', 'repository', 'pullRequest', 'reviewThreads', 'nodes') or {}
    local result = {}
    for _, thread in ipairs(threads) do
      -- Drop resolved threads entirely.
      if not thread.isResolved then
        local nodes = vim.tbl_get(thread, 'comments', 'nodes') or {}
        local thread_id = nodes[1] and nodes[1].databaseId
        for _, c in ipairs(nodes) do
          local effective_line = thread.isOutdated and c.originalLine or c.line
          local effective_start = thread.isOutdated and c.originalStartLine or c.startLine
          if not vim.isnil(effective_line) and not vim.isnil(c.path) then
            local reply_to
            if not vim.isnil(c.replyTo) and c.replyTo.databaseId then
              reply_to = c.replyTo.databaseId
            end
            table.insert(result, {
              id = c.databaseId,
              html_url = c.url,
              user = { login = (not vim.isnil(c.author)) and c.author.login or '?' },
              body = c.body or '',
              diff_hunk = c.diffHunk or '',
              path = c.path,
              line = effective_line,
              start_line = effective_start,
              updated_at = c.updatedAt,
              in_reply_to_id = reply_to,
              outdated = thread.isOutdated or false,
              thread_id = thread_id,
            })
          end
        end
      end
    end
    util.log('load_comments resp', { count = #result })
    cb(result)
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
function M.new_comment(pr, body, path, start_line, line, repo, cb)
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
    'side=RIGHT',
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

--- @param cb fun(prs: PullRequest[])
function M.get_pr_list(cb)
  local cmd = 'gh pr list --json ' .. table.concat(pr_fields, ',')
  util.system_str(cmd, function(resp, stderr)
    util.log('get_pr_list resp', resp)
    local prefix = 'Unknown JSON field'
    if string.sub(stderr, 1, #prefix) == prefix then
      -- Without "baseRefOid" field.
      local fields = vim
        .iter(pr_fields)
        :filter(function(v)
          return v ~= 'baseRefOid'
        end)
        :totable()
      util.system_str('gh pr list --json ' .. table.concat(fields, ','), function(resp2)
        util.log('get_pr_list resp', resp2)
        cb(parse_or_default(resp2, {}))
      end)
    else
      cb(parse_or_default(resp, {}))
    end
  end)
end

--- @param pr PullRequest
function M.checkout_pr(pr, cb)
  local branch = ('pr%s-%s'):format(pr.number, pr.author.login):gsub(' ', '_')
  util.system_str(f('gh pr checkout --force --branch %s %d', branch, pr.number), cb)
end

function M.approve_pr(number, cb)
  util.system_str(f('gh pr review %s -a', number), cb)
end

function M.request_changes_pr(number, body, cb)
  local request = {
    'gh',
    'pr',
    'review',
    f('%d', number),
    '-r',
    '--body',
    body,
  }

  util.log('request_changes_pr request', request)

  local result = util.system(request, function(result)
    util.log('request_changes_pr resp', result)
    cb(result)
  end)
end

function M.get_pr_diff(number, cb)
  util.system_str(f('gh pr diff %s', number), cb)
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

function M.get_user(cb)
  util.system_str('gh api user -q .login', function(result)
    if result ~= nil then
      cb(vim.split(result, '\n')[1])
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
