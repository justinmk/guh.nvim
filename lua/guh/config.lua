local M = {}

M.s = {
  debug = false,
  view_split = 'vsplit',
  diff_split = 'vsplit',
  comment_split = 'split',
  open_command = 'open',
  merge = {
    approved = '--squash',
    nonapproved = '--auto --squash',
  },
  html_comments_command = { 'lynx', '-stdin', '-dump' },
  keymaps = {
    diff = {
      open_file = 'gf',
      open_file_tab = '',
      open_file_split = 'o',
      open_file_vsplit = 'O',
      approve = 'cA',
      request_changes = 'cR',
    },
    comment = {
      send_comment = 'c<CR>',
    },
    pr = {
      approve = 'cA',
      request_changes = 'cR',
      merge = 'cM',
      comment = 'ca',
      diff = 'cp',
    },
  },
}

function M.setup(config)
  M.s = vim.tbl_deep_extend('force', {}, M.s, config)
end

function M.log(key, message)
  if M.s.debug then
    local log_file_name = vim.fn.stdpath('log') .. '/guh.log'
    local log_file = io.open(log_file_name, 'a')
    if log_file then
      log_file:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. key .. ':\n')
      log_file:write(vim.inspect(message))
      log_file:write('\n\n')
      log_file:close()
    end
  end
end

return M
