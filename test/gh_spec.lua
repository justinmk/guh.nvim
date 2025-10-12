---@diagnostic disable: redundant-return-value

-- TODO: do this in global test setup
vim.opt.runtimepath:append{
  vim.fn.getcwd() .. '/test/functional/guh.nvim/',
}

local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')
local clear, eq, eval, command, feed, insert, wait = n.clear, t.eq, n.eval, n.command, n.feed, n.insert, n.wait

local async = require('async')
local gh = require('guh.gh')
local pr_commands = require('guh.pr_commands')
local utils = require('guh.utils')
local state = require('guh.state')
local system_str_async = async.wrap(2, utils.system_str)
local get_pr_info_async = async.wrap(2, gh.get_pr_info)
local get_issue_async = async.wrap(2, gh.get_issue)

local tests = {}

function tests.test_get_pr_info()
  return async.run(function()
    local result = assert(system_str_async('gh pr list --json number'))
    local pr_num = assert(vim.json.decode(result)[1].number, 'failed to get a repo issue')

    local pr = get_pr_info_async(pr_num)
    assert(pr, 'pr is nil')
    assert(type(pr.number) == 'number', 'pr.number not number')
    assert(type(pr.title) == 'string', 'pr.title not string')
    assert(type(pr.author) == 'table', 'pr.author not table')
  end)
end

function tests.test_get_issue()
  return async.run(function()
    local result = system_str_async('gh issue list --json number')
    local issue_num = assert(vim.json.decode(assert(result))[1].number, 'failed to get a repo issue')

    local issue = get_issue_async(issue_num)
    assert(issue, 'issue is nil')
    assert(type(issue.number) == 'number', 'issue.number not number')
    assert(type(issue.title) == 'string', 'issue.title not string')
    assert(type(issue.author) == 'table', 'issue.author not table')
  end)
end

-- Tests hardcoded diff.
function tests.test_get_prepare_comment()
  local pr_id = 42
  local buf = state.get_buf('diff', pr_id)
  state.show_buf(buf)
  state.set_b_guh(buf, {
    id = pr_id,
    feat = 'diff',
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "diff --git a/lua/guh/config.lua b/lua/guh/config.lua",
    "index a573cc0..2cedcc0 100644",
    "--- a/lua/guh/config.lua",
    "+++ b/lua/guh/config.lua",
    "@@ -13,6 +13,7 @@ M.s = {",
    "   html_comments_command = { 'lynx', '-stdin', '-dump' },",
    "   keymaps = {",
    "     diff = {",
    "+      comment = 'cc',",
    "       open_file = 'gf',",
  })
  vim.api.nvim_win_set_cursor(0, {9, 0})  -- on "+      comment = 'cc',"

  local info = pr_commands.prepare_to_comment(9, 9)
  assert(info)
  assert('lua/guh/config.lua' == info.file)
  assert(16 == info.start_line, info.start_line)
  assert(16 == info.end_line, info.end_line)
  assert(pr_id == info.pr_id, info.pr_id)
  assert(buf == info.buf, info.buf)
end

-- Tests real comments response Github.
-- Calls load_comments() and asserts that some comments were loaded into quickfix.
function tests.test_get_comments()
  return async.run(function()
    local result = system_str_async('gh pr list --json number')
    local prs = assert(vim.json.decode(assert(result)), 'failed to get PRs')
    assert(#prs > 0, 'no PRs found')
    local pr_num = prs[1].number

    return async.await(function(callback)
      vim.schedule(function()
        require('guh.comments').load_comments(pr_num)

        -- Wait for quickfix to be populated or timeout
        local ok = vim.wait(5000, function()
          local qf = vim.fn.getqflist()
          return #qf > 0
        end)

        if ok then
          local qf = vim.fn.getqflist()
          assert(#qf > 0, 'quickfix list is empty')
          -- Check that entries have filename, lnum, text
          for _, entry in ipairs(qf) do
            assert(entry.filename, 'entry missing filename')
            assert(entry.lnum > 0, 'entry lnum not positive')
            assert(entry.text, 'entry missing text')
          end
        else
          -- If no comments, that's ok, but notify
          print('No comments found for PR ' .. pr_num .. ', test passed but no assertions')
        end

        callback()
      end)
    end)
  end)
end

-- Tests that ":Guh 1" shows the issue in a buffer.
function tests.test_Guh()
  return async.run(function()
    local result = assert(system_str_async('gh issue list --json number'))
    local issue_num = assert(vim.json.decode(result)[1].number, 'failed to get a repo issue')

    return async.await(function(callback)
      vim.schedule(function()
        -- Run the command
        vim.cmd(('Guh %d'):format(issue_num))

        -- Wait for the buffer to be created
        local ok, buf = vim.wait(5000, function()
          local b = vim.fn.bufnr(('guh://issue/%d'):format(issue_num))
          return b > 0, b
        end)
        assert(ok)

        -- Check the buffer content
        ---@diagnostic disable-next-line param-type-mismatch
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert(#lines > 0, 'buffer is empty')
        assert(lines[1]:match('#%d'), 'first line not issue title')
        callback()
      end)
    end)
  end)
end

describe('guh.gh', function()
  local screen
  before_each(function()
    clear()
    screen = Screen.new(80, 10)
    n.exec_lua[[
      -- TODO: do this in global test setup
      vim.opt.runtimepath:append{
        vim.fn.getcwd() .. '/test/functional/guh.nvim/',
      }
      require('guh').setup({})
    ]]
  end)

  it(':GuhDiff', function()
    n.command('GuhDiff 1')
    -- screen:snapshot_util()

    screen:expect{
      attr_ids = {}, -- Don't care about colors.
      grid = [[
        ^diff --git {MATCH:a/.* b/.* +}|
        new file mode {MATCH:%d+ +}|
        index {MATCH:.*}|
        --- {MATCH:.*}|
        +++ {MATCH:.*}|
        @@ {MATCH:.*} @@ {MATCH: +}|
        {MATCH:.*}|
        {MATCH:.*}|
        {MATCH:.*}|
        {MATCH:.*}|
      ]]
    }
  end)

  pending('get_pr_info', function()
    local task = tests.test_get_pr_info()
    local ok, err = task:wait(5000)
    assert(ok, err or 'get_pr_info failed')
  end)

  pending('get_issue', function()
    local task = tests.test_get_issue()
    local ok, err = task:wait(5000)
    assert(ok, err or 'get_issue failed')
  end)

  it('prepare_to_comment (static diff)', function()
    tests.test_get_prepare_comment({})
  end)

  pending('get_comments', function()
    local task = tests.test_get_comments()
    local ok, err = task:wait(5000)
    assert(ok, err or 'get_comments failed')
  end)

  pending('Guh command shows issue buffer', function()
    local task = tests.test_Guh()
    local ok, err = task:wait(5000)
    assert(ok, err or 'Guh command failed')
  end)
end)

--[[
local function main()
  require('guh').setup({})
  -- tests = { test_get_prepare_comment2 = tests.test_get_prepare_comment2 }

  -- Check if CWD is a GitHub repo that gh can work with
  -- local is_repo = async
  --   .run(function()
  --     return not not system_str_async('gh repo view --json nameWithOwner')
  --   end)
  --   :wait()
  -- if not is_repo then
  --   print('Not a GitHub repository or gh not configured')
  --   return
  -- end

  ---@type table<string, { desc?: string, task?: any, passed?: boolean }>
  local tasks = {}
  for testname, _ in pairs(tests) do
    tasks[testname] = {}
  end
  -- Start all tests as parallel tasks. Pass a context which they can augment.
  for testname, testfn in vim.spairs(tests) do
    local ctx = tasks[testname]
    ctx.task = testfn(ctx)
  end

  local all_passed = true
  async
    .run(function()
      for testname, ctx in vim.spairs(tasks) do
        local err
        if type(ctx.task) == 'table' and ctx.task.pwait then
          ctx.passed, err = ctx.task:pwait()
        else
          -- For non-async tests (which would have exited the process before now).
          ctx.passed = true
        end
        local name = ('%s%s'):format(testname, ctx.desc and (' %s'):format(ctx.desc) or '')
        print(('%s: %s'):format(ctx.passed and 'pass' or 'fail', name))
        if not ctx.passed and err then
          print(vim.text.indent(2, err))
        end
        all_passed = all_passed and not not ctx.passed
      end
      print('')
    end)
    :wait()
  if not all_passed then
    os.exit(1)
  end
end

main()
--]]
