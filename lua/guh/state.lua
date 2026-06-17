require('guh.types')

local M = {}

--- feat+id => bufnr
local bufs = {
  ---@type table<string, integer>
  comment = {},
  ---@type table<string, integer>
  commit = {},
  ---@type table<string, integer>
  edit = {},
  ---@type table<string, integer>
  issue = {},
  ---@type table<string, integer>
  merge = {},
  ---@type table<string, integer>
  pr = {},
  ---@type table<string, integer>
  prcomments = {},
  ---@type table<string, integer>
  prdiff = {},
  ---@type table<string, integer>
  prlogs = {},
  ---@type table<string, integer>
  review = {},
  ---@type table<string, integer>
  status = {},
}

--- Canonical `bufs[feat][?]` lookup key for a (repo, id) pair.
local function get_key(repo, id)
  return repo and ('%s/%s'):format(repo, id) or tostring(id)
end

--- Gets the existing buf or creates a new one, for the given PR + feature.
---
--- @param feat Feat
--- @param repo string|nil "owner/name", or nil for non-thing-bound feats ("guh://status").
--- @param id string|integer PR/issue number, or "all" for "guh://status".
--- @param create? boolean (default: true) If false, return nil instead of creating a new buf.
--- @return integer? buf
function M.get_buf(feat, repo, id, create)
  local key = get_key(repo, id)
  local b = bufs[feat][key]
  if type(b) == 'number' and vim.api.nvim_buf_is_valid(b) then
    return b
  end
  if create == false then
    return nil
  end
  b = vim.api.nvim_create_buf(true, true)
  -- We use buffers as "storage" => we get Vim's "lifecycle" for free.
  -- Explicitly set this even though nvim_create_buf (scratch) sets it implicitly.
  vim.bo[b].bufhidden = 'hide'
  bufs[feat][key] = b
  assert(type(b) == 'number')
  return b
end

--- Wipes the `guh://<repo>/<feat>/<id>` buf, and clears its `state.bufs` entry.
---
--- @param feat Feat
--- @param repo string|nil
--- @param id string|integer
function M.del_buf(feat, repo, id)
  local key = get_key(repo, id)
  local b = bufs[feat][key]
  bufs[feat][key] = nil
  if type(b) == 'number' and vim.api.nvim_buf_is_valid(b) then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end

--- Navigates to the window/tabpage of the specified buffer, or else shows it
--- in the current window.
--- @param buf integer
--- @param focus boolean Navigate to existing window where the buffer is visible.
local function show_buf(buf, focus)
  if not focus then
    vim.api.nvim_set_current_buf(buf)
    return
  end
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 0 then
    -- Already displayed elsewhere, focus it.
    vim.api.nvim_set_current_win(wins[1])
  else
    -- Not displayed, switch to it in the current win.
    vim.api.nvim_set_current_buf(buf)
  end
end

--- Tries to resolve the feat+repo+id buffer and navigate to it, else returns false.
---
--- @param feat Feat
--- @param repo string "owner/name"
--- @param id string|integer PR/issue number.
--- @return boolean true if the buffer exists and was focused, else false.
function M.try_show(feat, repo, id)
  local buf = assert(M.get_buf(feat, repo, id))
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 0 then
    -- Already displayed elsewhere, focus it.
    vim.api.nvim_set_current_win(wins[1])
    return true
  end
  return false
end

--- Gets the cached `pr_data` from the relevant `pr/…` buffer.
---
--- @param repo_or_buf string|integer "owner/name", or a `pr/…` buf number.
--- @param id? string|integer PR number (required when `repo_or_buf` is a repo).
--- @return PullRequest?
--- @return integer? pr_buf The `pr/…` buffer, or nil.
function M.get_pr_data(repo_or_buf, id)
  local pr_buf = id == nil and repo_or_buf or M.get_buf('pr', repo_or_buf, id, false)
  if type(pr_buf) ~= 'number' then
    return nil, nil
  end
  return (M.get_b_guh(pr_buf) or {}).pr_data, pr_buf
end

--- Gets the `b:guh` buffer-local dict (if any), or nil if `buf` is invalid.
--- @param buf? integer
--- @return BufState?
function M.get_b_guh(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  return vim.b[buf].guh
end

--- Sets the `b:guh` buffer-local dict. `bufstate` is merged with existing state, if any.
---
--- Note: To delete a field, set its value to `vim.NIL`:
--- ```lua
--- state.set_b_guh(pr_buf, { pr_data = vim.NIL })
--- ```
---
--- @param buf integer
--- @param bufstate BufState
function M.set_b_guh(buf, bufstate)
  local merged = vim.tbl_extend('force', vim.b[buf].guh or {}, bufstate)
  for k, v in pairs(bufstate) do
    if v == vim.NIL then
      merged[k] = nil
    end
  end
  vim.b[buf].guh = merged
end

--- @param feat Feat
--- @param focus boolean|nil Tristate:
---   - true: Navigate to existing window (if any).
---   - false: Show buf in current window.
---   - nil: Don't show the buf, only load/prepare it.
--- @param repo string|nil "owner/name", or nil for non-thing-bound feats ("guh://status").
--- @param id string|integer PR/issue number, or "all" for status.
--- @param bufstate? BufState
--- @return integer buf
--- @return string key the `(feat, key)` key
function M.init_buf(feat, focus, repo, id, bufstate)
  bufstate = bufstate or {}
  local key = get_key(repo, id)
  local buf = assert(M.get_buf(feat, repo, id))
  if focus ~= nil then
    show_buf(buf, focus)
  end
  if bufstate.id == nil then
    bufstate.id = id == 'all' and 0 or assert(vim._tointeger(id))
  end
  if bufstate.feat == nil then
    bufstate.feat = feat
  end
  if bufstate.repo == nil and repo then
    bufstate.repo = repo
  end
  -- XXX: Stash the key so anything (e.g. `util.run_term_cmds()`) can rebuild the `guh://…` URL,
  -- even for "global" (non-repo-specific) buffers like `guh://status`.
  bufstate.bufkey = key
  M.set_b_guh(buf, bufstate)
  M.set_buf_name(buf, feat, key)
  return buf, key
end

--- Resets `buf` to "not loaded" state so the next show_* will reload from scratch. Closes any
--- in-flight jobs/channels and clears cached payloads (`pr_data`). Idempotent.
---
--- @param buf integer
function M.invalidate(buf)
  local b_guh = M.get_b_guh(buf) or {}
  if b_guh.chan then
    pcall(vim.fn.chanclose, b_guh.chan)
  end
  for _, j in ipairs(b_guh.jobs or {}) do
    pcall(vim.fn.jobstop, j)
  end
  M.set_b_guh(buf, { chan = vim.NIL, jobs = vim.NIL, pr_data = vim.NIL })
end

--- Gets buffer URI:
--- - `guh://<owner>/<repo>/<feat>/<id>` for per-repo per-feature buffers.
--- - `guh://<feat>` for "global" buffers (`guh://status`).
---
--- @param feat Feat
--- @param key string PR/issue number, or "all" for status.
local function get_buf_name(feat, key)
  local owner, repo, n = key:match('^([^/]+)/([^/]+)/(.+)$')
  if owner then
    return ('guh://%s/%s/%s/%s'):format(owner, repo, feat, n)
  end
  return ('guh://%s'):format(feat)
end

--- Sets the buffer name to "guh://…/…" format.
function M.set_buf_name(buf, feat, key)
  local bufname = get_buf_name(feat, key)
  local prev_altbuf = vim.fn.bufnr('#')

  -- NOTE: This leaves orphan "term://~/…:/usr/local/bin/gh" buffers.
  --       Fixed upstream: https://github.com/neovim/neovim/pull/35951
  vim.api.nvim_buf_set_name(buf, bufname)
  -- vim.api.nvim_buf_call(buf, function()
  --   vim.cmd.file({ bufname, mods = { noautocmd = true } })
  -- end)

  -- XXX fucking hack because Vim creates new buffer after (re)naming it.
  local unwanted_altbuf = vim.fn.bufnr('#')
  if prev_altbuf ~= unwanted_altbuf and unwanted_altbuf > 0 and unwanted_altbuf ~= buf then
    vim.api.nvim_buf_delete(unwanted_altbuf, {})
  end

  -- Restore the alt buffer that was clobbered above.
  if prev_altbuf > 0 and prev_altbuf ~= buf and vim.api.nvim_buf_is_valid(prev_altbuf) then
    vim.fn.setreg('#', prev_altbuf)
  end
end

M.bufs = bufs

return M
