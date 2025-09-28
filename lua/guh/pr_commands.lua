local comments = require('guh.comments')
local config = require('guh.config')
local gh = require('guh.gh')
local pr_utils = require('guh.pr_utils')
local state = require('guh.state')
local utils = require('guh.utils')

local M = {}

--- @param buf integer
local function set_pr_view_keymaps(buf)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.approve, 'Approve PR', M.approve_pr)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.request_changes, 'Request PR changes', M.request_changes_pr)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.merge, 'Merge PR in remote repo', M.merge_pr)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.comment, 'Comment on PR', ':GuhComment<cr>')
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.diff, 'View the PR diff', ':GuhDiff<cr>')
end

--- @param buf integer
local function set_issue_view_keymaps(buf)
  utils.buf_keymap(buf, 'n', config.s.keymaps.pr.comment, 'Comment on issue', ':GuhComment<cr>')
end

--- @param cb fun(pr: PullRequest)
local function ui_selectPR(prompt, cb)
  local progress = utils.new_progress_report('Loading PR list...', vim.fn.bufnr())
  gh.get_pr_list(function(prs)
    if #prs == 0 then
      progress('failed', nil, 'No PRs found. Make sure you have `gh` configured.')
      return
    end

    vim.schedule(function()
      vim.ui.select(prs, {
        prompt = prompt,
        --- @param pr PullRequest
        format_item = function(pr)
          local date = pr.createdAt:sub(1, 10)
          local draft = pr.isDraft and ' Draft' or ''
          local approved = pr.reviewDecision == 'APPROVED' and ' Approved' or ''

          local labels = ''
          for _, label in pairs(pr.labels) do
            labels = labels .. ', ' .. label.name
          end

          return string.format(
            '#%s: %s (%s, %s%s%s%s)',
            pr.number,
            pr.title,
            pr.author.login,
            date,
            draft,
            approved,
            labels
          )
        end,
      }, function()
        progress('success')
        return cb()
      end)
    end)
  end)
end

--- @param opts table
--- @param on_pr fun(pr: PullRequest)
local function on_pr_select(opts, on_pr)
  local prnum = opts and opts.args and tonumber(opts.args)
  if prnum then
    pr_utils.get_selected_pr(prnum, on_pr)
  else
    ui_selectPR('Select PR:', function(pr)
      if pr ~= nil then
        on_pr(pr)
      end
    end)
  end
end

--- Shows PR info. Sets `b:guh_pr`.
---
local function show_pr_info(pr_info)
  if pr_info == nil then
    return utils.notify('PR view load failed', vim.log.levels.ERROR)
  end

  vim.schedule(function()
    local pr_view = {
      string.format('#%d %s', pr_info.number, pr_info.title),
      string.format('Created by %s at %s', pr_info.author.login, pr_info.createdAt),
      string.format('URL: %s', pr_info.url),
      string.format('Changed files: %d', pr_info.changedFiles),
    }

    if pr_info.isDraft then
      table.insert(pr_view, 'Draft')
    end

    if #pr_info.labels > 0 then
      local label_names = {}
      for _, label in pairs(pr_info.labels) do
        table.insert(label_names, label.name)
      end
      table.insert(pr_view, ('Labels: %s'):format(table.concat(label_names, ', ')))
    end

    if #pr_info.reviews > 0 then
      local review_parts = {}
      for _, review in pairs(pr_info.reviews) do
        table.insert(review_parts, ('%s (%s)'):format(review.author.login, review.state))
      end
      table.insert(pr_view, ('Reviews: %s'):format(table.concat(review_parts, ', ')))
    end

    table.insert(pr_view, '')
    local body = string.gsub(pr_info.body, '\r', '')
    for _, line in ipairs(vim.split(body, '\n')) do
      table.insert(pr_view, line)
    end

    table.insert(pr_view, '')
    if not utils.is_empty(config.s.keymaps.pr.approve) then
      table.insert(pr_view, 'Press ' .. config.s.keymaps.pr.approve .. ' to approve PR')
    end
    if not utils.is_empty(config.s.keymaps.pr.request_changes) then
      table.insert(pr_view, 'Press ' .. config.s.keymaps.pr.request_changes .. ' to request PR changes')
    end
    if not utils.is_empty(config.s.keymaps.pr.merge) then
      table.insert(pr_view, 'Press ' .. config.s.keymaps.pr.merge .. ' to merge PR')
    end
    if not utils.is_empty(config.s.keymaps.pr.comment) then
      table.insert(pr_view, 'Press ' .. config.s.keymaps.pr.comment .. ' to comment on PR')
    end
    if not utils.is_empty(config.s.keymaps.pr.diff) then
      table.insert(pr_view, 'Press ' .. config.s.keymaps.pr.diff .. ' to open PR diff')
    end

    if #pr_info.comments > 0 then
      table.insert(pr_view, '')
      table.insert(pr_view, 'Comments:')
      table.insert(pr_view, '')

      for _, comment in pairs(pr_info.comments) do
        table.insert(pr_view, string.format('✍️ %s at %s:', comment.author.login, comment.createdAt))

        local comment_body = string.gsub(comment.body, '\r', '')

        -- NOTE: naive check if it is HTML comment
        if config.s.html_comments_command ~= false and comment.body:match('<%s*[%w%-]+.-%s*>') ~= nil then
          local success, result = pcall(function()
            return vim.system(config.s.html_comments_command, { stdin = comment.body }):wait()
          end)
          if success then
            comment_body = result.stdout
          end
        end

        for _, line in ipairs(vim.split(comment_body, '\n')) do
          table.insert(pr_view, line)
        end
        table.insert(pr_view, '')
      end
    end

    local buf = state.get_buf('pr', pr_info.number)
    buf = state.try_set_buf_name(buf, 'pr', pr_info.number)
    vim.b[buf].guh_pr = pr_info

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].filetype = 'markdown'
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, pr_view)

    vim.bo[buf].readonly = true
    vim.bo[buf].modifiable = false

    set_pr_view_keymaps(buf)
  end)
end

--- Shows issue info. Sets `b:guh_issue`.
---
local function show_issue_info(issue_info)
  if issue_info == nil then
    return utils.notify('Issue view load failed', vim.log.levels.ERROR)
  end

  vim.schedule(function()
    local issue_view = {
      string.format('#%d %s', issue_info.number, issue_info.title),
      string.format('Created by %s at %s', issue_info.author.login, issue_info.createdAt),
      string.format('URL: %s', issue_info.url),
      string.format('State: %s', issue_info.state),
    }

    if issue_info.updatedAt ~= issue_info.createdAt then
      table.insert(issue_view, string.format('Updated at %s', issue_info.updatedAt))
    end

    if #issue_info.labels > 0 then
      local label_names = {}
      for _, label in pairs(issue_info.labels) do
        table.insert(label_names, label.name)
      end
      table.insert(issue_view, ('Labels: %s'):format(table.concat(label_names, ', ')))
    end

    table.insert(issue_view, '')
    local body = string.gsub(issue_info.body, '\r', '')
    for _, line in ipairs(vim.split(body, '\n')) do
      table.insert(issue_view, line)
    end

    table.insert(issue_view, '')
    if not utils.is_empty(config.s.keymaps.pr.comment) then
      table.insert(issue_view, 'Press ' .. config.s.keymaps.pr.comment .. ' to comment on issue')
    end

    local buf = state.get_buf('issue', issue_info.number)
    buf = state.try_set_buf_name(buf, 'issue', issue_info.number)
    vim.b[buf].guh_issue = issue_info

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].filetype = 'markdown'
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, issue_view)

    vim.bo[buf].readonly = true
    vim.bo[buf].modifiable = false

    set_issue_view_keymaps(buf)

    -- Load comments
    gh.load_issue_comments(issue_info.number, function(grouped_comments)
      if #grouped_comments > 0 then
        local comment_lines = { '', 'Comments:', '' }

        for _, group in pairs(grouped_comments) do
          for _, comment in pairs(group.comments) do
            table.insert(comment_lines, ('✍️ %s at %s:'):format(comment.user, comment.updated_at))

            local comment_body = string.gsub(comment.body, '\r', '')

            -- NOTE: naive check if it is HTML comment
            if config.s.html_comments_command ~= false and comment.body:match('<%s*[%w%-]+.-%s*>') ~= nil then
              local success, result = pcall(function()
                return vim.system(config.s.html_comments_command, { stdin = comment.body }):wait()
              end)
              if success then
                comment_body = result.stdout
              end
            end

            for _, line in ipairs(vim.split(comment_body, '\n')) do
              table.insert(comment_lines, line)
            end
            table.insert(comment_lines, '')
          end
        end

        vim.bo[buf].readonly = false
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, #issue_view, -1, false, comment_lines)
        vim.bo[buf].readonly = true
        vim.bo[buf].modifiable = false
      end
    end)
  end)
end

--- Shows one of:
--- - Status (if no args given)
--- - PR. Calls `show_pr_info`, which sets `b:guh_pr`.
--- - Issue. Calls `show_issue_info`, which sets `b:guh_issue`.
function M.select(opts)
  if 0 == #((opts or {}).args or {}) then
    M.show_status()
    return
  end
  local repo
  gh.get_repo(function(repo_)
    repo = repo_
  end)
  vim.wait(5000, function()
    return not not repo
  end)
  if not repo then
    utils.notify('Failed to get repo info', vim.log.levels.ERROR)
    return
  end
  local num = opts and opts.args and tonumber(opts.args)
  local test_cmd = vim.system({ 'gh', 'api', ('repos/%s/pulls/%s'):format(repo, num) }, { text = true }):wait()
  local is_pr = 0 == (test_cmd).code
  if is_pr and num then
    M.show_pr(num)
  elseif is_pr or not num then
    on_pr_select(opts, function(pr)
      gh.get_pr_info(pr.number, show_pr_info)
    end)
  else
    M.show_issue(num)
    -- gh.get_issue(num, show_issue_info)
    -- TODO: issue selection?
  end
end

--- Performs checkout. Shows PR info.
--- Calls `show_pr_info`, which sets `b:guh_pr`.
function M.checkout(opts)
  on_pr_select(opts, function(pr)
    gh.checkout_pr(pr, function()
      gh.get_pr_info(pr.number, show_pr_info)
    end)
  end)
end

--- Comment on a PR (bang "!") or a diff line/range.
M.comment = function(arg1, arg2)
  if type(arg1) == 'table' then -- opts from command
    comments.comment(arg1, arg2)
  else -- on_success from keymap, do PR comment
    comments.comment({ bang = true }, arg1)
  end
end

function M.approve_pr()
  pr_utils.get_selected_pr(function(pr)
    if pr == nil then
      return utils.notify('No PR selected', vim.log.levels.ERROR)
    end

    local progress = utils.new_progress_report('Approving...', vim.fn.bufnr())
    gh.approve_pr(pr.number, function()
      progress('success')
    end)
  end)
end

function M.request_changes_pr()
  pr_utils.get_selected_pr(function(pr)
    if pr == nil then
      return utils.notify('No PR selected', vim.log.levels.ERROR)
    end

    local progress = utils.new_progress_report('Requesting...', vim.fn.bufnr())
    vim.schedule(function()
      local prompt = '<!-- Type your comment and press '
        .. config.s.keymaps.comment.send_comment
        .. ' to request PR changes: -->'

      utils.edit_comment(pr.number, prompt, { prompt, '' }, config.s.keymaps.comment.send_comment, function(input)
        gh.request_changes_pr(pr.number, input, function() end)
        progress('success')
      end)
    end)
  end)
end

function M.merge_pr()
  pr_utils.get_selected_pr(function(pr)
    if pr == nil then
      return utils.notify('No PR selected to merge', vim.log.levels.ERROR)
    end

    local progress = utils.new_progress_report('Merging...', vim.fn.bufnr())
    local s = config.s.merge[pr.reviewDecision == 'APPROVED' and 'approved' or 'nonapproved']
    gh.merge_pr(pr.number, s, function()
      progress('success')
    end)
  end)
end

function M.show_status()
  local buf = state.get_buf('status', 'all')
  state.show_buf(buf)
  state.set_b_guh(buf, {
    id = 0,
    feat = 'status',
  })
  utils.run_term_cmd(buf, 'status', 'all', { 'gh', 'status' })
end

--- @param id integer
function M.show_issue(id)
  local buf = state.get_buf('issue', id)
  state.show_buf(buf)
  state.set_b_guh(buf, {
    id = id,
    feat = 'issue',
  })
  utils.run_term_cmd(buf, 'issue', id, { 'gh', 'issue', 'view', tostring(id) })
  set_issue_view_keymaps(buf)
end

function M.show_pr(id)
  local buf = state.get_buf('pr', id)
  state.show_buf(buf)
  state.set_b_guh(buf, {
    id = id,
    feat = 'pr',
  })
  utils.run_term_cmd(buf, 'pr', id, { 'gh', 'pr', 'view', '--comments', tostring(id) })
  set_pr_view_keymaps(buf)
end

function M.show_pr_diff(opts)
  local id = assert(opts and opts.args and tonumber(opts.args) or tonumber(opts) or (vim.b.guh or {}).id)

  local buf = state.get_buf('diff', id)
  state.show_buf(buf)
  state.set_b_guh(buf, {
    id = id,
    feat = 'diff',
  })
  utils.run_term_cmd(buf, 'diff', id, { 'gh', 'pr', 'diff', tostring(id) })
  set_pr_view_keymaps(buf)
end

return M
