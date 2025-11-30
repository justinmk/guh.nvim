---@diagnostic disable: redundant-return-value

local Screen = require('test.functional.ui.screen')
local n = require('test.functional.testnvim')()
local t = require('test.testutil')

local test_cwd = assert(os.getenv('TEST_CWD'))

local screen
before_each(function()
  n.clear {
    args = {
      '-c',
      ("cd '%s'"):format(test_cwd),
    },
  }
  n.exec [[
    set laststatus=2
  ]]
  screen = Screen.new(80, 10)
  n.exec_lua(function(cwd_)
    vim.cmd.cd(cwd_)
    -- TODO: do this in global test setup
    vim.opt.runtimepath:append {
      cwd_,
      -- vim.fn.getcwd() .. '/test/functional/guh.nvim/',
    }
    require('guh').setup({})
  end, test_cwd)
end)

describe('guh.gh', function()
  it('get_pr_info', function()
    n.exec_lua(function()
      local async = require('async')
      local gh = require('guh.gh')
      local util = require('guh.util')
      local system_str_async = async.wrap(2, util.system_str)
      local get_pr_info_async = async.wrap(2, gh.get_pr_info)

      local function test_get_pr_info()
        return async.run(vim.schedule_wrap(function()
          local result = assert(system_str_async('gh pr list --json number'))
          local pr_num = assert(vim.json.decode(result)[1].number, 'failed to get a repo issue')

          local pr = get_pr_info_async(pr_num)
          assert(pr, 'pr is nil')
          assert(type(pr.number) == 'number', 'pr.number not number')
          assert(type(pr.title) == 'string', 'pr.title not string')
          assert(type(pr.author) == 'table', 'pr.author not table')
        end))
      end
      local task = test_get_pr_info()
      task:wait(5000)
    end)
  end)

  it('get_pr_ci_logs', function()
    n.exec_lua(function()
      local gh = require('guh.gh')
      local util = require('guh.util')

      local done = false
      local logs = nil
      local err = nil

      util.system_str('gh pr view 9 --json number,headRefOid', function(result)
        if not result then
          err = 'failed to get PR'
          done = true
          return
        end

        local pr = vim.json.decode(result)
        if not pr then
          err = 'failed to parse PR'
          done = true
          return
        end

        -- Test get_pr_ci_logs with the PR
        gh.get_pr_ci_logs(pr, function(job_logs, job_err)
          logs = job_logs
          err = job_err
          done = true
        end)
      end)

      -- Wait for the callbacks to complete
      local ok = vim.wait(10000, function()
        return done
      end)
      assert(ok, 'get_pr_ci_logs timed out')

      -- Either logs should exist or an error message should exist
      assert(not err, ('error: %s'):format(err))
      assert(logs, 'no logs or error returned')
    end)
  end)

  it('get_pr_jobs (neovim PR 36727)', function()
    n.exec_lua(function()
      local gh = require('guh.gh')
      local util = require('guh.util')

      -- Switch to neovim repo
      vim.cmd.cd('/Users/justin/dev/neovim')

      local done = false
      local jobs = nil
      local err = nil

      -- Get PR info for neovim PR 36727 (has workflow runs and completed jobs)
      -- This tests get_pr_jobs functionality with actual data.
      -- Note: PR 35793 was the original issue, but it doesn't have accessible workflow
      -- runs via the API (may be related to fork state). PR 36727 has active runs with
      -- some jobs in "waiting" state, which the filter correctly skips.
      util.system_str('gh pr view 36727 --json number,headRefOid', function(result)
        if not result then
          err = 'failed to get PR'
          done = true
          return
        end

        local pr = vim.json.decode(result)
        if not pr then
          err = 'failed to parse PR'
          done = true
          return
        end

        -- Test get_pr_jobs with the PR
        gh.get_pr_jobs(pr, function(job_list, job_err)
          jobs = job_list
          err = job_err
          done = true
        end)
      end)

      -- Wait for the callbacks to complete
      local ok = vim.wait(10000, function()
        return done
      end)
      assert(ok, 'get_pr_jobs timed out')

      -- Should either have jobs or a clear error
      assert(not err, ('error: %s'):format(err or 'unknown'))
      assert(jobs and #jobs > 0, 'no jobs returned')
    end)
  end)

  it('get_issue', function()
    n.exec_lua(function()
      local async = require('async')
      local gh = require('guh.gh')
      local util = require('guh.util')
      local system_str_async = async.wrap(2, util.system_str)
      local get_issue_async = async.wrap(2, gh.get_issue)

      local function test_get_issue()
        return async.run(vim.schedule_wrap(function()
          local result = system_str_async('gh issue list --json number')
          local issue_num = assert(vim.json.decode(assert(result))[1].number, 'failed to get a repo issue')

          local issue = get_issue_async(issue_num)
          assert(issue, 'issue is nil')
          assert(type(issue.number) == 'number', 'issue.number not number')
          assert(type(issue.title) == 'string', 'issue.title not string')
          assert(type(issue.author) == 'table', 'issue.author not table')
        end))
      end

      local task = test_get_issue()
      task:wait(5000)
    end)
  end)
end)

describe('comments', function()
  it('load_comments', function()
    n.exec_lua(function()
      local function assert_comments(comments)
        assert(comments and vim.tbl_count(comments) > 0)

        -- Check structure: comments is table<string, GroupedComment[]>
        for path, grouped_comments in pairs(comments) do
          assert(type(path) == 'string', 'path should be string')
          assert(type(grouped_comments) == 'table', 'grouped_comments should be table')
          assert(#grouped_comments > 0, 'grouped_comments should not be empty')
          for _, grouped in ipairs(grouped_comments) do
            assert(grouped.id, 'grouped.id missing')
            assert(type(grouped.line) == 'number', 'grouped.line should be number')
            assert(
              type(grouped.start_line) == 'number' or grouped.start_line == vim.NIL,
              'grouped.start_line should be number or nil'
            )
            assert(type(grouped.url) == 'string', 'grouped.url should be string')
            assert(type(grouped.content) == 'string', 'grouped.content should be string')
            assert(type(grouped.comments) == 'table', 'grouped.comments should be table')
            assert(#grouped.comments > 0, 'grouped.comments should not be empty')
            for _, comment in ipairs(grouped.comments) do
              assert(comment.id, 'comment.id missing')
              assert(type(comment.url) == 'string', 'comment.url should be string')
              assert(type(comment.path) == 'string', 'comment.path should be string')
              assert(type(comment.line) == 'number', 'comment.line should be number')
              assert(
                type(comment.start_line) == 'number' or comment.start_line == vim.NIL,
                'comment.start_line should be number or nil'
              )
              assert(type(comment.user) == 'string', 'comment.user should be string')
              assert(type(comment.body) == 'string', 'comment.body should be string')
              assert(type(comment.updated_at) == 'string', 'comment.updated_at should be string')
              assert(type(comment.diff_hunk) == 'string', 'comment.diff_hunk should be string')
            end
          end
        end
      end

      -- Tests real comments response Github.
      -- Calls load_comments() and asserts that some comments were loaded into quickfix.
      local function test_load_comments()
        -- local result = system_str_async('gh pr list --json number')
        -- local prs = assert(vim.json.decode(assert(result)), 'failed to get PRs')
        -- assert(#prs > 0, 'no PRs found')
        local pr_num = 2
        require('guh.comments').load_comments(pr_num, assert_comments)

        -- Wait for quickfix to be populated or timeout
        local ok, qf = vim.wait(5000, function()
          local qf = vim.fn.getqflist()
          return #qf > 0, qf
        end)

        assert(ok and #qf > 0, 'load_comments did not set quickfix list')
        -- Check that entries have filename, lnum, text
        for _, entry in ipairs(qf) do
          assert(entry.lnum > 0, ('entry lnum not positive: %s'):format(vim.inspect(entry)))
          assert(entry.text, ('entry missing text: %s'):format(vim.inspect(entry)))
        end
      end

      test_load_comments()
    end)
  end)
end)

describe('features', function()
  it('prepare_to_comment (hardcoded diff)', function()
    n.exec_lua(function()
      local comments = require('guh.comments')
      local state = require('guh.state')

      local pr_id = 42
      local buf = state.get_buf('diff', pr_id)
      state.show_buf(buf)
      state.set_b_guh(buf, {
        id = pr_id,
        feat = 'diff',
      })

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        'diff --git a/lua/guh/config.lua b/lua/guh/config.lua',
        'index a573cc0..2cedcc0 100644',
        '--- a/lua/guh/config.lua',
        '+++ b/lua/guh/config.lua',
        '@@ -13,6 +13,7 @@ M.s = {',
        "   html_comments_command = { 'lynx', '-stdin', '-dump' },",
        '   keymaps = {',
        '     diff = {',
        "+      comment = 'cc',",
        "       open_file = 'gf',",
      })
      vim.api.nvim_win_set_cursor(0, { 9, 0 }) -- on "+      comment = 'cc',"

      local info = comments.prepare_to_comment(9, 9)
      assert(info)
      assert('lua/guh/config.lua' == info.file)
      assert(16 == info.start_line, info.start_line)
      assert(16 == info.end_line, info.end_line)
      assert(pr_id == info.pr_id, info.pr_id)
      assert(buf == info.buf, info.buf)
    end)
  end)
end)

describe('commands', function()
  it(':GuhDiff loads PR diff + comments split window', function()
    n.command('GuhDiff 1')

    screen:expect {
      timeout = 10000,
      attr_ids = {}, -- Don't care about colors.
      grid = [[
        ^diff --git {MATCH:a/.* b/.*}│  Empty line = no comment {MATCH:.*}|
        index {MATCH:.*}|
        --- {MATCH:.*}|
        +++ {MATCH:.*}|
        @@ {MATCH:.*} @@ {MATCH:.*}|
        {MATCH:.*}|*3
        {MATCH:guh://diff/1 .* guh://comments/1 +}|
        {MATCH:.*}|
      ]],
    }
  end)

  it('":Guh 1" shows issue/pr', function()
    n.command('Guh 1')

    screen:expect {
      attr_ids = {}, -- Don't care about colors.
      grid = [[
        ^{MATCH:.*#1 +}|
        {MATCH:.*}|*7
        {MATCH:guh://.*/1 .*}|
        {MATCH: +}|
      ]],
    }

    -- local buf = n.fn.bufname('%')
    -- t.ok(buf == 'guh://issue/1' or buf == 'guh://pr/1', 'guh://{pr,issue}/1', buf)
  end)
end)
