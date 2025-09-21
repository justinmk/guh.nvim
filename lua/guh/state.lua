require('guh.types')

local M = {}

--- @type PullRequest|nil
M.selected_PR = nil

--- @type table<string, GroupedComment[]>
M.comments_list = {}

--- @type integer|nil Diff view buffer id
M.diff_buffer_id = nil

--- @type table<string, table<number, number>>
M.filename_line_to_diff_line = {}

--- @type table<number, FileNameAndLinePair>
M.diff_line_to_filename_line = {}

--- feat+prnum => bufnr
local bufs = {
  ---@type table<string, integer>
  diff = {
  },
  ---@type table<string, integer>
  info = {
  },
}

--- Gets the buf for the given PR + feature, or creates a new one if not found.
--- @param feat 'diff'|'info'
--- @param prnum string|number
function M.get_buf(feat, prnum)
  local prnumstr = tostring(prnum)
  local b = bufs[feat][prnumstr]
  if type(b) ~= 'number' or vim.api.nvim_buf_is_valid(b) then
    b = vim.api.nvim_create_buf(false, true)
    bufs[feat][prnumstr] = b
    assert(type(b) == 'number')
  end
  return b
end

function M.try_set_buf_name(buf, feat, prnum)
  local bufname = ('guh://%s/%s'):format(feat, prnum)
  local foundbuf = vim.fn.bufnr(bufname)
  if foundbuf > 0 and buf ~= foundbuf then
    vim.api.nvim_set_current_buf(foundbuf)
    -- XXX fucking hack because Vim creates new buffer after (re)naming it.
    bufs[feat][tostring(prnum)] = foundbuf
    return foundbuf
  end
  -- if not vim.api.nvim_buf_get_name(buf):match('guh%:') then
  vim.api.nvim_buf_set_name(
    buf,
    ('guh://%s/%s'):format(feat, prnum)
  )
  -- XXX fucking hack because Vim creates new buffer after (re)naming it.
  bufs[feat][tostring(prnum)] = buf
  return buf
  -- end
end

M.bufs = bufs

return M
