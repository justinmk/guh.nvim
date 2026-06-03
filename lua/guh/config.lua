local M = {}

-- Default config.
M.s = {
  debug = false,
  merge = {
    approved = '--squash',
    nonapproved = '--auto --squash',
  },
  -- TODO: this was used to format HTML content.
  -- html_comments_command = { 'lynx', '-stdin', '-dump' },
  keymaps = {
    diff = {
      comment = 'cc',
      open_file = 'gf',
      open_file_tab = '',
      open_file_split = 'o',
      open_file_vsplit = 'O',
      approve = 'cA',
      request_changes = 'cR',
    },
    pr = {
      approve = 'cA',
      request_changes = 'cR',
      merge = 'cm',
      comment = 'cc',
      diff = 'gd',
    },
  },
}

function M.setup(config)
  M.s = vim.tbl_deep_extend('force', {}, M.s, config)
end

return M
