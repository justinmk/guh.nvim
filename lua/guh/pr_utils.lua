-- To avoid accidental confusion commands are working only with two types of PRs:
-- * Selected (some commands don't need PR to be checked out)
-- * Checked Out (if command expects checked out state then it should check out selected branch)
--
-- * Some commands might work either with selected or checked out PR depending on view (diff view vs buffer)
--
-- If there is branch checked out but no PR Selected then this PR becomes Selected.

local gh = require('guh.gh')
local state = require('guh.state')
local utils = require('guh.utils')

require('guh.types')

local M = {}

--- @overload fun(cb: fun(pr: PullRequest | nil))
--- @overload fun(pr_number: number | nil, cb: fun(pr: PullRequest | nil))
function M.get_selected_pr(arg1, arg2)
  local cb = assert(type(arg2) == 'function' and arg2 or arg1)
  local prnum = type(arg2) == 'function' and arg1 or nil
  if prnum then
    -- If user provided PR number as a command arg, fetch and set as "selected".
    gh.get_pr_info(prnum, function(pr_info)
      if pr_info then
        state.selected_PR = pr_info
        cb(pr_info)
      else
        utils.notify(('PR #%s not found'):format(prnum), vim.log.levels.ERROR)
        cb(nil)
      end
    end)
  elseif state.selected_PR ~= nil then
    return vim.schedule_wrap(cb)(state.selected_PR)
  else
    gh.get_current_pr(function(current_pr)
      if current_pr ~= nil then
        state.selected_PR = current_pr
        cb(current_pr)
      else
        cb(nil)
      end
    end)
  end
end

--- @return PullRequest|nil returns checked out pr or nil if user does not approve check out
local function approve_and_chechkout_selected_pr(cb)
  vim.schedule(function()
    local choice = vim.fn.confirm('Do you want to check out selected PR?', '&Yes\n&No', 1)

    if choice == 1 then
      utils.notify(string.format('Checking out PR #%d...', state.selected_PR.number))
      gh.checkout_pr(state.selected_PR.number, function()
        utils.notify('PR check out finished.')
        cb(state.selected_PR)
      end)
    end
  end)
end

function M.is_pr_checked_out(cb)
  if state.selected_PR == nil then
    cb(false)
  else
    utils.get_current_git_branch_name(function(current_branch)
      cb(state.selected_PR.headRefName == current_branch)
    end)
  end
end

--- @return PullRequest|nil returns pull request or nil in case pull request is not checked out
function M.get_checked_out_pr(cb)
  utils.get_current_git_branch_name(function(current_branch)
    if state.selected_PR ~= nil then
      if state.selected_PR.headRefName ~= current_branch then
        approve_and_chechkout_selected_pr(cb)
      else
        cb(state.selected_PR)
      end
    else
      gh.get_current_pr(function(current_pr)
        if current_pr ~= nil then
          state.selected_PR = current_pr
          cb(current_pr)
        else
          cb(nil)
        end
      end)
    end
  end)
end

return M
