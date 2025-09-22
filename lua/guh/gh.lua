local comments_utils = require('guh.comments_utils')
local config = require('guh.config')
local utils = require('guh.utils')

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

function M.get_current_pr(cb)
  utils.system_str(
    'gh pr view --json headRefName,headRefOid,number,baseRefName,baseRefOid,reviewDecision',
    vim.schedule_wrap(function(result, stderr)
      local prefix = 'Unknown JSON field'
      if result == nil then
        cb(nil)
        return
      elseif string.sub(stderr, 1, #prefix) == prefix then
        utils.system_str(
          'gh pr view --json headRefName,headRefOid,number,baseRefName,reviewDecision',
          function(result2)
            if result2 == nil then
              cb(nil)
              return
            end
            cb(parse_or_default(result2, nil))
          end
        )
      else
        cb(parse_or_default(result, nil))
      end
    end)
  )
end

--- @param cb fun(pr?: PullRequest2)
function M.get_pr_info(pr_number, cb)
  vim.schedule_wrap(utils.system_str)(
    f(
      'gh pr view %s --json url,author,title,number,labels,comments,reviews,body,changedFiles,isDraft,createdAt,headRefOid',
      pr_number
    ),
    function(result)
      if result == nil then
        cb(nil)
        vim.bo.busy = 0
        return
      end
      config.log('get_pr_info resp', result)

      cb(parse_or_default(result, nil))
    end
  )
end

local function get_repo(cb)
  utils.system_str('gh repo view --json nameWithOwner -q .nameWithOwner', function(result)
    if result ~= nil then
      cb(vim.split(result, '\n')[1])
    end
  end)
end

--- @params pr_number number
function M.load_comments(pr_number, cb)
  get_repo(function(repo)
    config.log('repo', repo)
    utils.system_str(f('gh api repos/%s/pulls/%d/comments', repo, pr_number), function(comments_json)
      local comments = parse_or_default(comments_json, {})
      config.log('comments', comments)

      local function is_valid_comment(comment)
        return comment.line ~= vim.NIL
      end

      comments = utils.filter_array(comments, is_valid_comment)
      config.log('Valid comments count', #comments)
      config.log('comments', comments)

      comments_utils.group_comments(comments, function(grouped_comments)
        config.log('Valid comments groups count:', #grouped_comments)
        config.log('grouped comments', grouped_comments)

        cb(grouped_comments)
      end)
    end)
  end)
end

function M.reply_to_comment(pr_number, body, reply_to, cb)
  get_repo(function(repo)
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
  get_repo(function(repo)
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
  get_repo(function(repo)
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
  get_repo(function(repo)
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

--- @param cb fun(prs: PullRequest2[])
function M.get_pr_list(cb)
  -- TODO(justinmk): this does not pull all the fields required by PullRequest2
  utils.system_str(
    'gh pr list --json number,title,author,createdAt,isDraft,reviewDecision,headRefName,headRefOid,baseRefName,baseRefOid,labels',
    function(resp, stderr)
      config.log('get_pr_list resp', resp)
      local prefix = 'Unknown JSON field'
      if string.sub(stderr, 1, #prefix) == prefix then
        utils.system_str(
          'gh pr list --json number,title,author,createdAt,isDraft,reviewDecision,headRefName,headRefOid,baseRefName,labels',
          function(resp2)
            config.log('get_pr_list resp', resp2)
            cb(parse_or_default(resp2, {}))
          end
        )
      else
        cb(parse_or_default(resp, {}))
      end
    end
  )
end

--- @param pr PullRequest2
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

return M
