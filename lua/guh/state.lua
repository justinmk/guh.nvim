require('guh.types')

local M = {}

--- feat+prnum => bufnr
local bufs = {
  ---@type table<string, integer>
  comment = {},
  ---@type table<string, integer>
  comments = {},
  ---@type table<string, integer>
  diff = {},
  ---@type table<string, integer>
  pr = {},
  ---@type table<string, integer>
  issue = {},
  ---@type table<string, integer>
  status = {},
}

--- Gets the existing buf or creates a new one, for the given PR + feature.
--- @param feat Feat
--- @param pr_or_issue string|number PR or issue number or "all" for special cases (e.g. status).
function M.get_buf(feat, pr_or_issue)
  local pr_or_issue_str = tostring(pr_or_issue)
  local b = bufs[feat][pr_or_issue_str]
  if type(b) ~= 'number' or not vim.api.nvim_buf_is_valid(b) then
    b = vim.api.nvim_create_buf(true, true)
    bufs[feat][pr_or_issue_str] = b
    assert(type(b) == 'number')
  end
  return b
end

--- Navigates to the window/tabpage of the specified buffer, or else shows it
--- in the current window.
function M.show_buf(buf)
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 0 then
    -- Already displayed elsewhere, focus it.
    vim.api.nvim_set_current_win(wins[1])
  else
    -- Not displayed, switch to it in the current win.
    vim.api.nvim_set_current_buf(buf)
  end
end

--- Tries to resolve the feat+id buffer and navigate to it, else returns false.
---
--- @param feat Feat
--- @param pr_or_issue string|number PR or issue number or "all" for special cases (e.g. status).
--- @return boolean true if the feat+id buffer exists and was focused, else false.
function M.try_show(feat, pr_or_issue)
  local buf = M.get_buf(feat, pr_or_issue)
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 0 then
    -- Already displayed elsewhere, focus it.
    vim.api.nvim_set_current_win(wins[1])
    return true
  end
  return false
end

--- Sets the `b:guh` buffer-local dict. `bufstate` is merged with existing state, if any.
--- @param buf integer
--- @param bufstate BufState
function M.set_b_guh(buf, bufstate)
  local b_guh = vim.b[buf].guh
  if not b_guh then
    vim.b[buf].guh = bufstate
  else
    vim.b[buf].guh = vim.tbl_extend('force', b_guh, bufstate)
  end
end

--- @param feat Feat
--- @param pr_or_issue string|number PR or issue number or "all" for special cases (e.g. status).
--- @param bufstate? BufState
function M.init_buf(feat, pr_or_issue, bufstate)
  bufstate = bufstate or {}
  local buf = M.get_buf(feat, pr_or_issue)
  M.show_buf(buf)
  if not bufstate.id then
    bufstate['id'] = pr_or_issue == 'all' and 0 or assert(tonumber(pr_or_issue))
  end
  if not bufstate.feat then
    bufstate.feat = feat
  end
  M.set_b_guh(buf, bufstate)
  M.set_buf_name(buf, feat, pr_or_issue)
  return buf
end

local function get_buf_name(feat, id)
  return ('guh://%s/%s'):format(feat, id)
end

--- Sets the buffer name to "guh://…/…" format.
function M.set_buf_name(buf, feat, id)
  local bufname = get_buf_name(feat, id)
  local prev_altbuf = vim.fn.bufnr('#')

  -- NOTE: This leaves orphan "term://~/…:/usr/local/bin/gh" buffers.
  --       Fixed upstream: https://github.com/neovim/neovim/pull/35951
  vim.api.nvim_buf_set_name(buf, bufname)
  -- vim.api.nvim_buf_call(buf, function()
  --   vim.cmd.file({ bufname, mods = { noautocmd = true } })
  -- end)

  -- XXX fucking hack because Vim creates new buffer after (re)naming it.
  local unwanted_altbuf = vim.fn.bufnr('#')
  if prev_altbuf ~= unwanted_altbuf and unwanted_altbuf > 0 and unwanted_altbuf ~= buf then
    vim.api.nvim_buf_delete(unwanted_altbuf, {})
  end
end

-- M.on_win_open = function()
--   vim.cmd [[
--      vertical topleft split
--      set wrap breakindent nonumber norelativenumber nolist
--    ]]
-- end

M.bufs = bufs

return M
