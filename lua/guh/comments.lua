local config = require('guh.config')
local gh = require('guh.gh')
local utils = require('guh.utils')

local M = {}

local severity = vim.diagnostic.severity

local function load_comments_to_quickfix_list(comments_list)
  local qf_entries = {}
  local filenames = {}
  for fn in pairs(comments_list) do
    table.insert(filenames, fn)
  end
  table.sort(filenames)

  for _, filename in pairs(filenames) do
    local comments_in_file = comments_list[filename]
    table.sort(comments_in_file, function(a, b)
      return a.line < b.line
    end)
    for _, comment in pairs(comments_in_file) do
      if #comment.comments > 0 then
        table.insert(qf_entries, {
          filename = filename,
          lnum = comment.line,
          text = comment.content,
        })
      end
    end
  end

  if #qf_entries > 0 then
    vim.fn.setqflist(qf_entries, 'r')
    vim.cmd('cfirst')
  else
    utils.notify('No GH comments loaded.')
  end
end

---@param prnum integer
function M.load_comments(prnum, bufnr)
  local progress = utils.new_progress_report('Loading comments', vim.fn.bufnr())
  assert(type(prnum) == 'number')
  gh.get_pr_info(prnum, function(pr)
    if not pr then
      utils.notify(('PR #%s not found'):format(prnum), vim.log.levels.ERROR)
      progress('failed')
      return
    else
      vim.schedule_wrap(function()
        gh.load_comments(pr.number, function(comments_list)
          vim.schedule(function()
            load_comments_to_quickfix_list(comments_list)

            progress('success')
          end)
        end)
      end)
    end
  end)
end

M.update_comment = function(opts)
  utils.notify('TODO')
end

-- TODO: fix this, code is outdated after big refactor.
-- TODO: Somewhere we probably want to call this based on the quickfix filename:comments mapping.
M.load_comments_into_diagnostics = function(bufnr, filename, comments_list)
  vim.schedule(function()
    config.log('load_comments_into_diagnostics:', filename)
    if not comments_list or comments_list[filename] == nil then
      utils.notify(('comments_list[%s] is empty'):format(filename))
    else
      local diagnostics = {}
      for _, comment in pairs(comments_list[filename]) do
        if #comment.comments > 0 then
          config.log('comment to diagnostics', comment)
          table.insert(diagnostics, {
            lnum = comment.line - 1,
            col = 0,
            message = comment.content,
            severity = severity.INFO,
            source = 'guh.nvim',
          })
        end
      end

      vim.diagnostic.set(vim.api.nvim_create_namespace('guh.comments'), bufnr, diagnostics, {})
    end
  end)
end

return M
