local M = {}

M.setup = function()
  local group = vim.api.nvim_create_augroup('guh.keymaps', { clear = true })

  -- ":edit guh://pr/owner/repo/N" (etc.) dispatches to :Guh.
  -- Wipe the placeholder buffer that :edit created.
  vim.api.nvim_create_autocmd('BufReadCmd', {
    pattern = 'guh://*',
    group = group,
    callback = function(args)
      local uri = args.match
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          vim.api.nvim_buf_delete(args.buf, { force = true })
        end
        vim.cmd('Guh ' .. vim.fn.fnameescape(uri))
      end)
    end,
  })

  vim.api.nvim_create_autocmd('BufFilePost', {
    pattern = 'guh://*',
    group = group,
    callback = function(args)
      vim.keymap.set('n', '<CR>', function()
        local util = require('guh.util')
        local text = vim.fn.expand('<cWORD>')
        -- Flash the cWORD so the user can see what got picked.
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        local line = vim.api.nvim_get_current_line()
        local s = (line:sub(1, col + 1):match('()%S+$') or col + 2) - 1
        vim.hl.range(
          0,
          vim.api.nvim_create_namespace('guh.cword_hl'),
          'Visual',
          { row - 1, s },
          { row - 1, s + #text },
          { timeout = 200 }
        )
        local done = util.progress('Loading...')
        vim.schedule(function()
          vim.cmd('Guh ' .. text)
          done()
        end)
      end, { buffer = args.buf, desc = 'Open :Guh target at cursor' })
    end,
  })

  vim.api.nvim_create_user_command('Guh', function(opts)
    require('guh.pr_commands').select(opts)
  end, { nargs = '?' })
  vim.api.nvim_create_user_command('GuhComment', function(opts)
    require('guh.pr_commands').comment(opts)
  end, { bang = true, range = true })
end

return M
