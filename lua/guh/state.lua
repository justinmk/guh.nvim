require('guh.types')

local M = {}

--- The current checked-out PR.
--- @type PullRequest|nil
M.selected_PR = nil

--- @type integer|nil Diff view buffer id
M.diff_buffer_id = nil

--- feat+prnum => bufnr
local bufs = {
  ---@type table<string, integer>
  comment = {},
  ---@type table<string, integer>
  diff = {},
  ---@type table<string, integer>
  info = {},
}

--- Gets the buf for the given PR + feature, or creates a new one if not found.
--- @param feat 'diff'|'info'|'comment'
--- @param prnum string|number
function M.get_buf(feat, prnum)
  local prnumstr = tostring(prnum)
  local b = bufs[feat][prnumstr]
  if type(b) ~= 'number' or vim.api.nvim_buf_is_valid(b) then
    b = vim.api.nvim_create_buf(true, true)
    bufs[feat][prnumstr] = b
    assert(type(b) == 'number')
  end
  return b
end

function M.try_set_buf_name(buf, feat, prnum)
  local bufname = ('guh://%s/%s'):format(feat, prnum)
  local foundbuf = vim.fn.bufnr(bufname)
  if foundbuf > 0 and buf ~= foundbuf then
    local existing_wins = vim.fn.win_findbuf(foundbuf)
    if #existing_wins > 0 then
      -- Already displayed elsewhere, focus it
      vim.api.nvim_set_current_win(existing_wins[1])
      bufs[feat][tostring(prnum)] = foundbuf
      return foundbuf
    else
      -- Not displayed, switch to reuse the buffer
      vim.api.nvim_set_current_buf(foundbuf)
      -- XXX fucking hack because Vim creates new buffer after (re)naming it.
      bufs[feat][tostring(prnum)] = foundbuf
      return foundbuf
    end
  end
  -- New buffer, set name and display in split
  vim.api.nvim_buf_set_name(buf, bufname)
  -- XXX fucking hack because Vim creates new buffer after (re)naming it.
  bufs[feat][tostring(prnum)] = buf
  M.on_win_open()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
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
