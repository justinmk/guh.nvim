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
--- @param prnum string
function M.get_buf(feat, prnum)
  local prnumstr = tostring(prnum)
  local b = bufs[feat][prnumstr]
  if type(b) ~= 'number' or vim.api.nvim_buf_is_valid(b) then
    b = vim.api.nvim_create_buf(false, true)
    bufs[feat][prnumstr] = b
  end
  return b
end

return M
