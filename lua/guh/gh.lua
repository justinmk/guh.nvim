local async = require('async')
local config = require('guh.config')
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
--- @param cmd string gh command
--- @param b_field string b:guh field to check for (and store) cached data.
local function get_info(cmd, b_field, cb)
  -- Use b:guh cache on the current buffer, if available.
  local b_guh = vim.b.guh
  if b_guh and b_guh[b_field] then
    cb(b_guh[b_field])
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  vim.schedule_wrap(util.system_str)(cmd, function(result, stderr)
    if result == nil then
      cb(nil)
      return
    elseif stderr:match('Unknown JSON field') then
      error(('Unknown JSON field: %s'):format(stderr))
      local r = parse_or_default(result, nil)
      state.set_b_guh(buf, { [b_field] = r })
      cb(r)
    end
    config.log('get_info resp', result)

    local r = parse_or_default(result, nil)
    state.set_b_guh(buf, { [b_field] = r })
    cb(r)
  end)
end

--- Gets PR data from b:guh, or requests it from the API.
---
--- @param prnum string|number PR number, or empty for "current PR"
--- @param cb fun(pr?: PullRequest)
function M.get_pr_info(prnum, cb)
  local cmd = f('gh pr view %s --json %s', prnum, table.concat(pr_fields, ','))
  get_info(cmd, 'pr_data', cb)
end

--- @param issue_num string|number Issue number
--- @param cb fun(issue?: Issue)
function M.get_issue(issue_num, cb)
  local cmd = f('gh issue view %s --json %s', issue_num, table.concat(issue_fields, ','))
  get_info(cmd, 'issue_data', cb)
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

--- @param type 'pulls'|'issues'
function M.load_comments(type, number, cb)
  assert(cb)
  local log_type = type == 'pulls' and 'pr' or 'issue'
  M.get_repo(function(repo)
    config.log('repo', repo)
    util.system_str(f('gh api repos/%s/%s/%d/comments', repo, type, number), function(comments_json)
      local comments = parse_or_default(comments_json, {})
      local function is_valid_comment(comment)
        return comment.line ~= vim.NIL
      end

      local nr_before = #comments
      comments = util.filter_array(comments, is_valid_comment)
      config.log(
        ('%s comments (valid: %s, discarded: %s)'):format(log_type, #comments, nr_before - #comments),
        comments
      )

      cb(comments)
    end)
  end)
end

function M.reply_to_comment(prnum, body, reply_to, cb)
  M.get_repo(function(repo)
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
    config.log('reply_to_comment request', request)

    util.system(request, function(result)
      local resp = parse_or_default(result, { errors = {} })

      config.log('reply_to_comment resp', resp)
      cb(resp)
    end)
  end)
end

function M.new_comment(pr, body, path, start_line, line, cb)
  M.get_repo(function(repo)
    local commit_id = assert(pr.headRefOid)

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

    config.log('new_comment request', request)

    util.system(request, function(result)
      local resp = parse_or_default(result, { errors = {} })
      config.log('new_comment resp', resp)
      cb(resp)
    end)
  end)
end

function M.new_pr_comment(pr, body, cb)
  local request = {
    'gh',
    'pr',
    'comment',
    f('%d', pr.number),
    '--body',
    body,
  }

  config.log('new_pr_comment request', request)

  local result = util.system(request, function(result)
    config.log('new_pr_comment resp', result)
    cb(result)
  end)
end

function M.update_comment(comment_id, body, cb)
  M.get_repo(function(repo)
    local request = {
      'gh',
      'api',
      '--method',
      'PATCH',
      f('repos/%s/pulls/comments/%s', repo, comment_id),
      '-f',
      'body=' .. body,
    }
    config.log('update_comment request', request)

    util.system(request, function(result)
      local resp = parse_or_default(result, { errors = {} })
      config.log('update_comment resp', resp)
      cb(resp)
    end)
  end)
end

function M.delete_comment(comment_id, cb)
  M.get_repo(function(repo)
    local request = {
      'gh',
      'api',
      '--method',
      'DELETE',
      f('repos/%s/pulls/comments/%s', repo, comment_id),
    }
    config.log('delete_comment request', request)

    util.system(request, function(resp)
      config.log('delete_comment resp', resp)
      cb(resp)
    end)
  end)
end

--- @param cb fun(prs: PullRequest[])
function M.get_pr_list(cb)
  local cmd = 'gh pr list --json ' .. table.concat(pr_fields, ',')
  util.system_str(cmd, function(resp, stderr)
    config.log('get_pr_list resp', resp)
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
        config.log('get_pr_list resp', resp2)
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

  config.log('request_changes_pr request', request)

  local result = util.system(request, function(result)
    config.log('request_changes_pr resp', result)
    cb(result)
  end)
end

function M.get_pr_diff(number, cb)
  util.system_str(f('gh pr diff %s', number), cb)
end

function M.merge_pr(number, options, cb)
  util.system_str(f('gh pr merge %s %s', number, options), cb)
end

function M.get_user(cb)
  util.system_str('gh api user -q .login', function(result)
    if result ~= nil then
      cb(vim.split(result, '\n')[1])
    end
  end)
end

--- Gets all jobs from the most recent workflow run for a PR commit.
---
--- TODO: example of how to get workflow runs: https://github.com/pwntester/octo.nvim/blob/e6cef8d1889be92b7393717750fa5af5b6890ad3/lua/octo/workflow_runs.lua#L682-L708
---
--- @param pr PullRequest
--- @param cb fun(jobs?: table[], error?: string)
function M.get_pr_jobs(pr, cb)
  local head_sha = pr.headRefOid

  -- Get the most recent workflow run for this commit
  local run_request = {
    'gh',
    'api',
    'repos/:owner/:repo/actions/runs',
    '-q',
    '.workflow_runs | map(select(.head_sha == "' .. head_sha .. '")) | sort_by(.created_at) | reverse | .[0].id',
  }

  util.system(run_request, function(run_id)
    run_id = vim.trim(run_id or '')
    if run_id == '' or run_id == 'null' then
      cb(nil, f('No workflow runs found for PR #%s', pr.number))
      return
    end

    -- Get all jobs in that workflow run
    local jobs_request = {
      'gh',
      'api',
      f('repos/:owner/:repo/actions/runs/%s/jobs', run_id),
      '-q',
      '.jobs',
    }

    util.system(jobs_request, function(jobs_json)
      local jobs = parse_or_default(jobs_json, {})
      if #jobs == 0 then
        cb(nil, f('No jobs found in workflow run %s', run_id))
      else
        cb(jobs)
      end
    end)
  end)
end

--- Gets CI logs for the latest commit in the PR.
---
--- TODO: example of how to get logs: https://github.com/pwntester/octo.nvim/blob/e6cef8d1889be92b7393717750fa5af5b6890ad3/lua/octo/workflow_runs.lua#L292-L299
---
--- @param pr PullRequest
--- @param cb fun(logs?: string, error?: string)
function M.get_pr_ci_logs(pr, cb)
  local head_sha = pr.headRefOid

  -- Get the most recent workflow run for this commit
  local run_request = {
    'gh',
    'api',
    'repos/:owner/:repo/actions/runs',
    '-q',
    '.workflow_runs | map(select(.head_sha == "' .. head_sha .. '")) | sort_by(.created_at) | reverse | .[0].id',
  }

  util.system(run_request, function(run_id)
    run_id = vim.trim(run_id or '')
    if run_id == '' or run_id == 'null' then
      cb(nil, f('No workflow runs found for PR #%s', pr.number))
      return
    end

    -- Get all jobs in that workflow run and find one with logs
    -- (skip jobs in "waiting" status as they have no logs)
    local job_request = {
      'gh',
      'api',
      f('repos/:owner/:repo/actions/runs/%s/jobs', run_id),
      '-q',
      '.jobs | map(select(.status != "waiting")) | sort_by(.started_at) | reverse | .[0].id',
    }

    util.system(job_request, function(job_id)
      job_id = vim.trim(job_id or '')
      if job_id == '' or job_id == 'null' then
        cb(nil, f('No jobs with logs found in workflow run %s', run_id))
        return
      end

      -- Get logs for that job
      local logs_request = {
        'gh',
        'run',
        'view',
        run_id,
        '--job',
        job_id,
        '--log',
      }

      util.system(logs_request, cb)
    end)
  end)
end

M.get_repo_async = async.wrap(1, M.get_repo)

return M
