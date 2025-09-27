local async = require('async')
local gh = require('guh.gh')
local utils = require('guh.utils')

local system_str_async = async.wrap(2, utils.system_str)
local get_pr_info_async = async.wrap(2, gh.get_pr_info)
local get_issue_async = async.wrap(2, gh.get_issue)

local tests = {}

function tests.test_get_pr_info(ctx)
  return async.run(function()
    local result = system_str_async('gh pr list --json number')
    local pr_num = assert(vim.json.decode(assert(result))[1].number, 'failed to get a repo issue')
    ctx.desc = ('(pr=%s)'):format(pr_num)

    local pr = get_pr_info_async(pr_num)
    assert(pr, 'pr is nil')
    assert(type(pr.number) == 'number', 'pr.number not number')
    assert(type(pr.title) == 'string', 'pr.title not string')
    assert(type(pr.author) == 'table', 'pr.author not table')
  end)
end

function tests.test_get_issue(ctx)
  return async.run(function()
    local result = system_str_async('gh issue list --json number')
    local issue_num = assert(vim.json.decode(assert(result))[1].number, 'failed to get a repo issue')
    ctx.desc = ('(issue=%s)'):format(issue_num)

    local issue = get_issue_async(issue_num)
    assert(issue, 'issue is nil')
    assert(type(issue.number) == 'number', 'issue.number not number')
    assert(type(issue.title) == 'string', 'issue.title not string')
    assert(type(issue.author) == 'table', 'issue.author not table')
  end)
end

-- Tests that ":Guh 1" shows the issue in a buffer.
function tests.test_Guh(ctx)
  return async.run(function()
    local result = system_str_async('gh issue list --json number')
    local issue_num = assert(vim.json.decode(assert(result))[1].number, 'failed to get a repo issue')
    ctx.desc = ('(issue=%s)'):format(issue_num)

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

local function main()
  require('guh').setup({})

  -- Check if CWD is a GitHub repo that gh can work with
  local is_repo = async
    .run(function()
      return not not system_str_async('gh repo view --json nameWithOwner')
    end)
    :wait()

  if not is_repo then
    print('Not a GitHub repository or gh not configured')
    return
  end

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
        ctx.passed, err = ctx.task:pwait()
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
