require('guh.types')

local M = {}

--- The current checked-out PR.
--- @type PullRequest|nil
M.selected_PR = nil

--- feat+prnum => bufnr
local bufs = {
  ---@type table<string, integer>
  comment = {},
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
--- @param pr_or_issue string|number PR or issue number or 'none' for special cases (e.g. status).
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

local function get_buf_name(feat, id)
  return ('guh://%s/%s'):format(feat, id)
end

function M.set_buf_name(buf, feat, id)
  local bufname = get_buf_name(feat, id)
  -- New buffer, set name and display in split
  vim.api.nvim_buf_set_name(buf, bufname)
  -- XXX fucking hack because Vim creates new buffer after (re)naming it.
  bufs[feat][tostring(id)] = buf
end

function M.try_set_buf_name(buf, feat, id)
  local bufname = get_buf_name(feat, id)
  local foundbuf = vim.fn.bufnr(bufname)
  if foundbuf > 0 and buf ~= foundbuf then
    M.show_buf(foundbuf)
    -- XXX fucking hack because Vim creates new buffer after (re)naming it.
    bufs[feat][tostring(id)] = foundbuf
    return foundbuf
  end
  M.set_buf_name(buf, feat, id)
  M.show_buf(buf)
  M.on_win_open()
  return buf
end

M.on_win_open = function()
  vim.cmd [[
     vertical topleft split
     set wrap breakindent nonumber norelativenumber nolist
   ]]
end

M.bufs = bufs

return M
