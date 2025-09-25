local gh = require('guh.gh')
local utils = require('guh.utils')

local function run_test_asserts(assert_func)
  local passed = true
  local error_msg
  local success, err = pcall(assert_func)
  if not success then
    passed = false
    error_msg = err
  end
  return passed, error_msg
end

local function test_get_pr_info(cb)
  -- Get a PR number
  utils.system_str('gh pr list --json number', function(result)
    local pr_num = assert(vim.json.decode(assert(result))[1].number, 'failed to get a repo issue')

    gh.get_pr_info(pr_num, function(pr)
      local function run_asserts()
        assert(pr, 'pr is nil')
        assert(type(pr.number) == 'number', 'pr.number not number')
        assert(type(pr.title) == 'string', 'pr.title not string')
        assert(type(pr.author) == 'table', 'pr.author not table')
      end
      local passed, error_msg = run_test_asserts(run_asserts)
      cb({ name = ('get_pr_info (pr=%s)'):format(pr_num), passed = passed, error = error_msg })
    end)
  end)
end

local function test_get_issue(cb)
  -- Get an issue number
  utils.system_str('gh issue list --json number', function(result)
    local issue_num = assert(vim.json.decode(assert(result))[1].number, 'failed to get a repo issue')

    gh.get_issue(issue_num, function(issue)
      local function run_asserts()
        assert(issue, 'issue is nil')
        assert(type(issue.number) == 'number', 'issue.number not number')
        assert(type(issue.title) == 'string', 'issue.title not string')
        assert(type(issue.author) == 'table', 'issue.author not table')
      end
      local passed, error_msg = run_test_asserts(run_asserts)
      cb({ name = ('get_issue (issue=%s)'):format(issue_num), passed = passed, error = error_msg })
    end)
  end)
end

local function main()
  -- Check if CWD is a GitHub repo that gh can work with
  local repo_checked = false
  local is_repo = false
  utils.system_str('gh repo view --json nameWithOwner', function(result)
    is_repo = result ~= nil
    repo_checked = true
  end)

  -- Wait for repo check
  vim.wait(5000, function()
    return repo_checked
  end)

  if not is_repo then
    print('Not a GitHub repository or gh not configured')
    return
  end

  local results = {}
  local cb = function(res)
    results[res.name] = res
  end

  local expected_tests = 2
  test_get_pr_info(cb)
  test_get_issue(cb)

  -- Wait for async operations to complete
  vim.wait(10000, function()
    return vim.tbl_count(results) >= expected_tests
  end)

  -- Print results in order
  for name, res in vim.spairs(results) do
    print(('%s: %s'):format(res.passed and 'pass' or 'fail', name))
    if res.error then
      print(res.error)
    end
  end

  if vim.iter(results):any(function(_, r)
    return not r.passed
  end) then
    os.exit(1)
  end
end

main()
