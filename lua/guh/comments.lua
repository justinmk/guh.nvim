local config = require('guh.config')
local gh = require('guh.gh')
local state = require('guh.state')
local util = require('guh.util')

local M = {}

local severity = vim.diagnostic.severity

local function load_comments_to_quickfix_list(comments_list)
  local qf_entries = {}

  for filename, comments_in_file in vim.spairs(comments_list) do
    table.sort(comments_in_file, function(a, b)
      return a.line < b.line
    end)
    for _, comment in pairs(comments_in_file) do
      local cs = comment.comments
      if #cs > 0 then
        table.insert(qf_entries, {
          filename = filename,
          lnum = comment.line,
          -- text = comment.content,
          text = cs[1].body .. (cs[2] and (' (+%s more)'):format(vim.tbl_count(cs)) or ''),
        })
      end
    end
  end

  if #qf_entries > 0 then
    vim.fn.setqflist(qf_entries, 'u')
  else
    util.notify('No GH comments loaded.')
  end
end

--- Loads comments for a given diff in a vertical window, where each comment is vertically aligned
--- with the diff line that it annotates.
local function show_comments_in_scrollbind_win(id, diff_win, comments_list)
  local diff_buf = vim.api.nvim_win_get_buf(diff_win)
  local diff_lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)

  vim.cmd[[botright vertical split]]
  local buf = state.init_buf('comments', id)

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  -- match window options of diff
  vim.wo.wrap = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.list = false
  vim.wo.scrollbind = true

  -- also scrollbind diff window
  local prev = diff_win
  local cur = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(prev)
  vim.wo.scrollbind = true
  vim.api.nvim_set_current_win(cur)

  ---------------------------------------------------------------------------
  -- Step 1: Parse diff → map each *visible line* to its file + "new" line num
  ---------------------------------------------------------------------------
  local file = nil
  local new_line = 0
  local hunk_start = 0
  local line_map = {} ---@type table<integer, {file:string,new_line:integer|nil}>
  for i, l in ipairs(diff_lines) do
    local plusfile = l:match('^%+%+%+ b/(.+)$')
    if plusfile then
      file = plusfile
      new_line = 0
      hunk_start = 0
    end

    local hunk_new = l:match('^@@ [^+]+%+(%d+)')
    if hunk_new then
      new_line = tonumber(hunk_new)
      hunk_start = i
    elseif file then
      local c = l:sub(1, 1)
      if c == '+' or c == ' ' then
        line_map[i] = { file = file, new_line = new_line }
        new_line = new_line + 1
      elseif c == '-' then
        line_map[i] = { file = file, new_line = nil }
      end
    end
  end

  ---------------------------------------------------------------------------
  -- Step 2: Build text lines for the comment buffer
  ---------------------------------------------------------------------------
  local lines = {}
  for i = 1, #diff_lines do
    lines[i] = ''
  end

  local function normalize_diff_path(p)
    p = p:gsub('^b/', '') -- remove Git diff prefix
    p = p:gsub('^a/', '')
    return p
  end

  for filename, comments_for_file in pairs(comments_list) do
    local normalized_filename = normalize_diff_path(filename)
    for _, comment in ipairs(comments_for_file) do
      local gh_line = comment.line
      local idx
      -- for i, m in pairs(line_map) do
      --   if i < 10 then
      --     vim.print({ i = i, file = m.file, old = m.old_line, new = m.new_line })
      --   else
      --     break
      --   end
      -- end
      for i, m in pairs(line_map) do
        local normalized_mfile = normalize_diff_path(m.file)
        if normalized_mfile == normalized_filename and m.new_line == gh_line then
          idx = i
          break
        end
      end
      if idx then
        local body
        if comment.body then
          body = comment.body
        elseif comment.comments then
          body = table.concat(
            vim.tbl_map(function(c)
              return c.body or ''
            end, comment.comments),
            '\n'
          )
        end
        if body and body ~= '' then
          local prefix = ('# %s:%d'):format(filename, gh_line)
          lines[idx] = (lines[idx] ~= '' and lines[idx] .. '\n' or '') .. prefix .. '\n> ' .. body:gsub('\n', '\n> ')
        end
      end
    end
  end

  ---------------------------------------------------------------------------
  -- Step 3: Write to buffer
  ---------------------------------------------------------------------------
  vim.bo[buf].modifiable = true

  -- Flatten multiline entries into individual lines
  local out = {}
  for _, v in ipairs(lines) do
    if v == '' then
      table.insert(out, '')
    else
      for sub in v:gmatch('[^\n]+') do
        table.insert(out, sub)
      end
    end
  end
  -- error(vim.inspect(buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)

  -- vim.bo[buf].modifiable = false
  -- vim.bo[buf].readonly = true
end

---@param prnum integer
function M.load_comments(prnum, bufnr)
  local progress = util.new_progress_report('Loading comments', vim.fn.bufnr())
  assert(type(prnum) == 'number')
  gh.load_comments(
    prnum,
    vim.schedule_wrap(function(comments_list)
      load_comments_to_quickfix_list(comments_list)
      show_comments_in_scrollbind_win(prnum, vim.api.nvim_get_current_win(), comments_list)
      progress('success')
    end)
  )
end

M.update_comment = function(opts)
  util.notify('TODO')
end

-- TODO: fix this, code is outdated after big refactor.
-- TODO: Somewhere we probably want to call this based on the quickfix filename:comments mapping.
M.load_comments_into_diagnostics = function(bufnr, filename, comments_list)
  vim.schedule(function()
    config.log('load_comments_into_diagnostics:', filename)
    if not comments_list or comments_list[filename] == nil then
      util.notify(('comments_list[%s] is empty'):format(filename))
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
