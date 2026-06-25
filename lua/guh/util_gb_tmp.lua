--- Temporary module, until "gb" is upstreamed to Nvim.
---
--- Implements "gb": jump to the `file[:line[:col]]` reference at cursor, for already-open buffers,
--- incl. URI buffers).

local M = {}

--- One leading/trailing punctuation char to peel when resolving a file reference. Excludes path and
--- spec chars (`/ . : - _ ~ # %`), so "doc/guh.txt:102" stays intact while "(util.lua:307)," doesn't.
local fileref_edge = '[%(%)%[%]<>{}\'"`,;!?*]'

--- Parses a "file", "file:line", or "file:line:col" reference (a trailing ":" is tolerated, e.g.
--- grep/rg output). `line`/`col` are nil if absent. The non-greedy file capture keeps URIs intact
--- (e.g. "guh://owner/repo/pr/13" has no trailing ":<num>", so the whole string is the file).
---
--- @param s string
--- @return string file, integer? line, integer? col
local function parse_fileref(s)
  local file, line, col = s:match('^(.-):(%d+):(%d+):?$')
  if file and file ~= '' then
    return file, tonumber(line), tonumber(col)
  end
  file, line = s:match('^(.-):(%d+):?$')
  if file and file ~= '' then
    return file, tonumber(line)
  end
  return s
end

--- Finds a loaded buffer whose name is `file`, or ends with "/"..`file` (path-suffix on a "/"
--- boundary). Matches URI buffers (e.g. "guh://…") as well as filesystem-backed ones. Prefers an
--- exact match; else the first suffix match.
---
--- A bare, trivial word ("a", "is" — no path separator and no extension) is too loose to suffix-match
--- and only ever resolves via an exact buffer name. The exception is an explicit relative path like
--- "./a": the leading "./" marks it path-like, so even a 1-char basename may suffix-match (→ "…/a").
---
--- @param file string
--- @return integer? buf
local function find_fileref_buf(file)
  if file == '' then
    return nil
  end
  local norm = file:gsub('^%./', '') -- "./a" -> "a" (explicit relative path).
  -- Suffix-matchable only if "path-like": contains "/", had a stripped "./", or has an extension.
  local path_like = file:find('/') ~= nil or file ~= norm or norm:find('%.[%w]') ~= nil
  local suffix = '/' .. norm
  local match
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == file or name == norm then
        return buf -- Exact match wins.
      elseif path_like and not match and #name > #suffix and name:sub(-#suffix) == suffix then
        match = buf -- Remember first suffix match; keep looking for an exact one.
      end
    end
  end
  return match
end

--- Jumps to the file reference under the cursor, if it names a currently-open buffer.
---
--- The cursor "word" (`<cWORD>`) is parsed as `file[:line[:col]]` (e.g. "lua/guh/util.lua:307:5"),
--- peeling surrounding punctuation until it resolves to a loaded buffer (à la `gf` for already-open
--- buffers). Matches URI buffers (e.g. "guh://…"), not only filesystem-backed ones. On a hit,
--- focuses the buffer (reusing its window if visible) and moves the cursor to `line:col` if present.
---
--- @return integer? buf the focused buffer, or nil if nothing resolved.
function M.goto_file_at_cursor()
  local candidate = vim.fn.expand('<cWORD>')
  for _ = 1, 10 do
    if candidate == '' then
      break
    end
    local file, line, col = parse_fileref(candidate)
    local buf = find_fileref_buf(file)
    if buf then
      local win = vim.fn.bufwinid(buf)
      if win ~= -1 then
        vim.api.nvim_set_current_win(win)
      else
        vim.api.nvim_set_current_buf(buf)
      end
      if line then
        local lnum = math.min(line, vim.api.nvim_buf_line_count(buf))
        local text = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ''
        vim.api.nvim_win_set_cursor(0, { lnum, math.max(0, math.min((col or 1) - 1, #text)) })
        pcall(vim.cmd, 'normal! zv') -- Open folds at the destination.
      end
      return buf
    end
    -- No hit: peel one punctuation layer (one char per end, then trailing sentence dots) and retry.
    local trimmed = candidate:gsub('^' .. fileref_edge, ''):gsub(fileref_edge .. '$', ''):gsub('%.+$', '')
    if trimmed == candidate then
      break
    end
    candidate = trimmed
  end
  return nil
end

return M
