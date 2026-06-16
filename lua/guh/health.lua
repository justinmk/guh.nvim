--- `:checkhealth guh` reports gh-cli auth status and current GitHub API rate-limit.

local M = {}

local function check_gh_cli()
  vim.health.start('guh: gh CLI')
  if vim.fn.executable('gh') == 0 then
    vim.health.error('`gh` not found on $PATH', { 'Install: https://cli.github.com' })
    return false
  end
  local r = vim.system({ 'gh', '--version' }, { text = true }):wait()
  if r.code ~= 0 then
    vim.health.error('`gh --version` failed: ' .. vim.trim(r.stderr or ''))
    return false
  end
  vim.health.ok(vim.trim((r.stdout or ''):match('^[^\n]*') or 'gh found'))
  return true
end

local function check_auth()
  vim.health.start('guh: authentication')
  local user = require('guh.gh').get_user()
  if user then
    vim.health.ok(('logged in as %s'):format(user))
  else
    vim.health.error('not logged in', { 'Run: gh auth login' })
  end
  return user ~= nil
end

local function check_rate_limit()
  vim.health.start('guh: GitHub API rate limit')
  local r = vim.system({ 'gh', 'api', 'rate_limit' }, { text = true }):wait()
  if r.code ~= 0 then
    vim.health.error('`gh api rate_limit` failed: ' .. vim.trim(r.stderr or ''))
    return
  end
  local ok, data = pcall(vim.json.decode, r.stdout)
  if not ok or not data.resources then
    vim.health.error('failed to parse rate_limit response')
    return
  end
  for name, rl in pairs(data.resources) do
    local msg = ('%-12s %d/%d, resets %s'):format(
      name,
      rl.remaining or 0,
      rl.limit or 0,
      rl.reset and os.date('%H:%M:%S', rl.reset) or '?'
    )
    if (rl.remaining or 0) == 0 then
      vim.health.error('rate-limited: ' .. msg)
    elseif (rl.remaining or 0) < (rl.limit or 1) * 0.1 then
      vim.health.warn(msg)
    else
      vim.health.info(msg)
    end
  end
end

local function check_last_seen()
  vim.health.start('guh: last-seen rate-limit (passive)')
  local rl = require('guh.gh').rate_limit
  if not rl.limited then
    vim.health.ok('none')
    return
  end
  local when = rl.checked_at and (' at +%dms'):format(rl.checked_at) or ''
  vim.health.warn(('hit %s rate limit%s'):format(rl.kind or '?', when), { rl.message or '' })
end

function M.check()
  if not check_gh_cli() then
    return
  end
  if not check_auth() then
    return
  end
  check_rate_limit()
  check_last_seen()
end

return M
