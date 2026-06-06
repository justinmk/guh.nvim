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
  screen = Screen.new(100, 10)
  n.exec_lua(function(cwd_)
    vim.cmd.cd(cwd_)
    -- TODO: do this in global test setup
    vim.opt.runtimepath:append {
      cwd_,
      -- vim.fn.getcwd() .. '/test/functional/guh.nvim/',
    }
    -- plugin/*.lua is auto-sourced at startup only; source manually since we just added the plugin path.
    vim.cmd('runtime! plugin/*.lua')
    assert(vim.fn.maparg('<Plug>(guh-diff)', 'n') ~= '', '<Plug>(guh-diff) not registered')
  end, test_cwd)
end)

describe('guh.gh', function()
  it('get_pr_data', function()
    n.exec_lua(function()
      local async = require('async')
      local gh = require('guh.gh')
      local util = require('guh.util')
      local system_async = async.wrap(2, util.system)
      local get_pr_data_async = async.wrap(4, gh.get_pr_data)

      local function test_get_pr_data()
        return async.run(function()
          local result = assert(system_async({ 'gh', 'pr', 'list', '--json', 'number' }))
          local pr_num = assert(vim.json.decode(result)[1].number, 'failed to get a repo issue')

          async.await(vim.schedule)
          local pr = get_pr_data_async(pr_num, 'justinmk/guh.nvim', nil)
          assert(pr, 'pr is nil')
          assert(type(pr.number) == 'number', 'pr.number not number')
          assert(type(pr.title) == 'string', 'pr.title not string')
          assert(type(pr.author) == 'table', 'pr.author not table')
        end)
      end
      local task = test_get_pr_data()
      task:wait(5000)
    end)
  end)

  it('get_pr_ci_jobs_logs + get_pr_ci_logs', function()
    n.exec_lua(function()
      local gh = require('guh.gh')
      local util = require('guh.util')

      local done = false
      local logs = nil
      local err = nil

      util.system({ 'gh', 'pr', 'view', '9', '--json', 'number,headRefOid' }, function(stdout, _, code)
        if code ~= 0 then
          err = 'failed to get PR'
          done = true
          return
        end

        local pr = vim.json.decode(stdout)
        if not pr then
          err = 'failed to parse PR'
          done = true
          return
        end

        gh.get_pr_ci_jobs_logs(pr, 'justinmk/guh.nvim', function(jobs, jobs_err)
          if not jobs then
            err = jobs_err
            done = true
            return
          end
          assert(#jobs > 0, 'no CI jobs returned')
          assert(jobs[1].databaseId, 'job missing databaseId')
          assert(type(jobs[1].name) == 'string', 'job missing name')

          gh.get_pr_ci_logs(jobs[1].databaseId, 'justinmk/guh.nvim', function(job_logs, job_err)
            logs = job_logs
            err = job_err
            done = true
          end)
        end)
      end)

      local ok = vim.wait(15000, function()
        return done
      end)
      assert(ok, 'get_pr_ci_logs timed out')

      -- Logs may have been purged by GitHub (90 day retention). Either logs or
      -- a "log unavailable" error is acceptable; a crash or timeout is not.
      assert(logs or err, 'no result returned')
      if err then
        assert(err:match('[Ll]og unavailable') or err:match('HTTP 410'), ('unexpected error: %s'):format(err))
      end
    end)
  end)
end)

describe('pr + comments view', function()
  it('get_pr_data + to_threads', function()
    n.exec_lua(function()
      local function assert_threads(threads_by_path)
        assert(threads_by_path and vim.tbl_count(threads_by_path) > 0)

        -- Check structure: threads_by_path is table<string, CommentThread[]>
        for path, threads in pairs(threads_by_path) do
          assert(type(path) == 'string', 'path should be string')
          assert(type(threads) == 'table', 'threads should be table')
          assert(#threads > 0, 'threads should not be empty')
          for _, thread in ipairs(threads) do
            assert(thread.id, 'thread.id missing')
            assert(type(thread.line) == 'number', 'thread.line should be number')
            assert(
              type(thread.start_line) == 'number' or thread.start_line == vim.NIL,
              'thread.start_line should be number or nil'
            )
            assert(type(thread.url) == 'string', 'thread.url should be string')
            assert(type(thread.comments) == 'table', 'thread.comments should be table')
            assert(#thread.comments > 0, 'thread.comments should not be empty')
            for _, comment in ipairs(thread.comments) do
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

      -- Tests real PR data from Github. Mirrors the flow in pr.show_pr_diff:
      -- gh.get_pr_data (force) → outdated-path rewrite → comments.to_threads.
      local function test_get_pr_data_full()
        local pr_num = 2
        local done = false
        require('guh.gh').get_pr_data(pr_num, 'justinmk/guh.nvim', { force = true }, function(pr)
          assert(pr, 'pr is nil')
          assert(type(pr.viewed) == 'table', 'pr.viewed should be table')
          assert(type(pr.raw_comments) == 'table', 'pr.raw_comments should be table')
          for _, c in ipairs(pr.raw_comments) do
            if c.outdated and c.thread_id then
              c.path = ('outdated-%d:%s'):format(c.thread_id, c.path)
            end
          end
          require('guh.comments').to_threads(pr.raw_comments, function(threads_by_path)
            assert_threads(threads_by_path)
            done = true
          end)
        end)
        assert(
          vim.wait(5000, function()
            return done
          end),
          'get_pr_data timed out'
        )
      end

      test_get_pr_data_full()
    end)
  end)
end)

describe('features', function()
  it('prepare_to_comment (hardcoded diff)', function()
    n.exec_lua(function()
      local comments = require('guh.comments')
      local state = require('guh.state')

      local pr_id = 42
      local buf = state.get_buf('prdiff', pr_id)
      state.show_buf(buf)
      state.set_b_guh(buf, {
        id = pr_id,
        feat = 'prdiff',
        repo = 'justinmk/guh.nvim',
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
  it(':Guh + dd loads PR diff + comments split window', function()
    n.command('Guh 1')
    -- Wait for the PR diff-view.
    t.retry(nil, 10000, function()
      assert('' ~= n.fn.maparg('dd', 'n', false))
    end)
    -- Invoke the diff-view.
    n.feed('<Plug>(guh-diff)')
    t.retry(nil, 10000, function()
      assert(2 == n.eval("winnr('$')"), tostring(n.eval("execute('map <buffer>')")))
    end)

    n.command('set nowrap signcolumn=no')
    t.retry(nil, nil, function()
      n.command('2 wincmd w')
    end)
    -- XXX: jiggle the comments viewport so the overlay appears. Is this a virt_lines bug?
    n.feed('<C-y>')

    -- Note: "Viewed" state is per-user, so we can't assert (N/M viewed) or (viewed) rows.
    screen:expect {
      timeout = 10000,
      attr_ids = {}, -- Don't care about colors.
      grid = [[
        {MATCH:PR diff.*}│{MATCH:PR comments.*}|
        diff --git {MATCH:a/.* b/.*}│^{MATCH:.*}|
        index {MATCH:.*}|
        --- {MATCH:.*}|
        +++ {MATCH:.*}|
        @@ {MATCH:.*} @@ {MATCH:.*}|
        {MATCH:.*}|*2
        {MATCH:guh://.*/prdiff/1 .* guh://.*/prcomments/1 +}|
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

describe('util', function()
  it('parse_target()', function()
    local function parse_target(arg)
      return n.exec_lua(function(a)
        return require('guh.util').parse_target(a)
      end, arg)
    end

    t.eq({ id = 13 }, parse_target('13'))
    t.eq({ id = 13 }, parse_target('  13  '))
    t.eq(
      { owner = 'justinmk', repo = 'guh.nvim', id = 13, is_pr = true },
      parse_target('https://github.com/justinmk/guh.nvim/pull/13')
    )
    t.eq(
      { owner = 'neovim', repo = 'neovim', id = 20632, is_pr = false },
      parse_target('https://github.com/neovim/neovim/issues/20632')
    )
    t.eq({ owner = 'neovim', repo = 'neovim', id = 20632 }, parse_target('neovim/neovim#20632'))
    t.eq(
      { owner = 'justinmk', repo = 'guh.nvim', id = 24, is_pr = true },
      parse_target('guh://justinmk/guh.nvim/pr/24')
    )
    t.eq(
      { owner = 'justinmk', repo = 'guh.nvim', id = 24, is_pr = true },
      parse_target('guh://justinmk/guh.nvim/prdiff/24')
    )
    t.eq({ owner = 'neovim', repo = 'neovim', id = 24 }, parse_target('guh://neovim/neovim/issue/24'))

    t.eq(nil, parse_target('garbage'))
    t.eq(nil, parse_target(''))
    t.eq(nil, parse_target('owner/repo'))
    t.eq(nil, parse_target('https://github.com/owner/repo'))
  end)
end)
