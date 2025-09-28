local comments_utils = require('guh.comments_utils')
local config = require('guh.config')
local utils = require('guh.utils')
local state = require('guh.state')

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
local function get_info(cmd, cb)
  vim.schedule_wrap(utils.system_str)(cmd, function(result, stderr)
    if result == nil then
      cb(nil)
      return
    elseif stderr:match('Unknown JSON field') then
      error(('Unknown JSON field: %s'):format(stderr))
      cb(parse_or_default(result, nil))
    end
    config.log('get_info resp', result)

    cb(parse_or_default(result, nil))
  end)
end

--- @param prnum string|number PR number, or empty for "current PR"
--- @param cb fun(pr?: PullRequest)
function M.get_pr_info(prnum, cb)
  local cmd = f('gh pr view %s --json %s', prnum, table.concat(pr_fields, ','))
  get_info(cmd, cb)
end

--- @param issue_num string|number Issue number
--- @param cb fun(issue?: Issue)
function M.get_issue(issue_num, cb)
  local cmd = f('gh issue view %s --json %s', issue_num, table.concat(issue_fields, ','))
  get_info(cmd, cb)
end

function M.get_repo(cb)
  utils.system_str('gh repo view --json nameWithOwner -q .nameWithOwner', function(result)
    if result ~= nil then
      cb(vim.split(result, '\n')[1])
    end
  end)
end

local function load_comments(type, number, cb)
  M.get_repo(function(repo)
    config.log('repo', repo)
    utils.system_str(f('gh api repos/%s/%s/%d/comments', repo, type, number), function(comments_json)
      local comments = parse_or_default(comments_json, {})
      config.log(('%s comments'):format(type), comments)

      local function is_valid_comment(comment)
        return comment.line ~= vim.NIL
      end

      comments = utils.filter_array(comments, is_valid_comment)
      config.log(('Valid %s comments count'):format(type), #comments)
      config.log(('%s comments'):format(type), comments)

      comments_utils.group_comments(comments, function(grouped_comments)
        config.log(('Valid %s comments groups count:'):format(type), #grouped_comments)
        config.log(('grouped %s comments'):format(type), grouped_comments)

        cb(grouped_comments)
      end)
    end)
  end)
end

--- @params pr_number number
function M.load_comments(pr_number, cb)
  load_comments('pulls', pr_number, cb)
end

--- @param issue_number number
function M.load_issue_comments(issue_number, cb)
  load_comments('issues', issue_number, cb)
end

function M.reply_to_comment(pr_number, body, reply_to, cb)
  M.get_repo(function(repo)
    local request = {
      'gh',
      'api',
      '--method',
      'POST',
      f('repos/%s/pulls/%d/comments', repo, pr_number),
      '-f',
      'body=' .. body,
      '-F',
      'in_reply_to=' .. reply_to,
    }
    config.log('reply_to_comment request', request)

    utils.system(request, function(result)
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

    utils.system(request, function(result)
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

  local result = utils.system(request, function(result)
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

    utils.system(request, function(result)
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

    utils.system(request, function(resp)
      config.log('delete_comment resp', resp)
      cb(resp)
    end)
  end)
end

--- @param cb fun(prs: PullRequest[])
function M.get_pr_list(cb)
  local cmd = 'gh pr list --json ' .. table.concat(pr_fields, ',')
  utils.system_str(cmd, function(resp, stderr)
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
      utils.system_str('gh pr list --json ' .. table.concat(fields, ','), function(resp2)
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
  utils.system_str(f('gh pr checkout --force --branch %s %d', branch, pr.number), cb)
end

function M.approve_pr(number, cb)
  utils.system_str(f('gh pr review %s -a', number), cb)
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

  local result = utils.system(request, function(result)
    config.log('request_changes_pr resp', result)
    cb(result)
  end)
end

function M.get_pr_diff(number, cb)
  utils.system_str(f('gh pr diff %s', number), cb)
end

function M.merge_pr(number, options, cb)
  utils.system_str(f('gh pr merge %s %s', number, options), cb)
end

function M.get_user(cb)
  utils.system_str('gh api user -q .login', function(result)
    if result ~= nil then
      cb(vim.split(result, '\n')[1])
    end
  end)
end

function M.show_status()
  local buf = state.get_buf('status', 'all')
  state.show_buf(buf)
  utils.run_term_cmd({ 'gh', 'status' })
end

function M.show_issue(id)
  local buf = state.get_buf('issue', 'all')
  state.show_buf(buf)
  utils.run_term_cmd({ 'gh', 'status', 'view', tostring(id) })
end

function M.show_pr(id)
  local buf = state.get_buf('pr', 'all')
  state.show_buf(buf)
  utils.run_term_cmd({ 'gh', 'pr', 'view', tostring(id) })
end

return M
