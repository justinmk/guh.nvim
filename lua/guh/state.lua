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

return M
