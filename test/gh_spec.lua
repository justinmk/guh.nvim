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

  it('get_pr_data populates ci_jobs + get_pr_ci_log', function()
    n.exec_lua(function()
      local gh = require('guh.gh')

      local done = false
      local logs = nil
      local err = nil

      -- `pr_data.ci_jobs` is batched into the `get_pr_data` GraphQL query.
      gh.get_pr_data(9, 'justinmk/guh.nvim', { force = true }, function(pr)
        if not pr then
          err = 'failed to get PR'
          done = true
          return
        end
        local jobs = pr.ci_jobs or {}
        assert(#jobs > 0, 'no CI jobs returned')
        assert(jobs[1].databaseId, 'job missing databaseId')
        assert(type(jobs[1].name) == 'string', 'job missing name')

        gh.get_pr_ci_log(jobs[1].databaseId, 'justinmk/guh.nvim', function(job_logs, job_err)
          logs = job_logs
          err = job_err
          done = true
        end)
      end)

      local ok = vim.wait(15000, function()
        return done
      end, 100)
      assert(ok, 'get_pr_ci_logs timed out')

      -- Logs may have been purged by GitHub (90 day retention). Either logs or
      -- a "log unavailable" error is acceptable; a crash or timeout is not.
      assert(logs or err, 'no result returned')
      if err then
        assert(err:match('[Ll]og unavailable') or err:match('HTTP 410'), ('unexpected error: %s'):format(err))
      end
    end)
  end)

  it('to_ci_jobs: extracts databaseId+runId, dedupes by name, drops non-actions/skipped, sorts', function()
    n.exec_lua(function()
      local to_ci_jobs = require('guh.gh')._to_ci_jobs

      -- Shape: a `node` with `headCommit.nodes[1].commit.statusCheckRollup.contexts.nodes[]`.
      local function ctx(name, conclusion, started_at, job_id, opts)
        opts = opts or {}
        return {
          __typename = opts.typename or 'CheckRun',
          name = name,
          conclusion = conclusion,
          status = opts.status or 'COMPLETED',
          startedAt = started_at,
          detailsUrl = job_id and ('https://github.com/o/r/actions/runs/777/job/%d'):format(job_id) or nil,
          checkSuite = { app = { slug = opts.slug or 'github-actions' } },
        }
      end

      local node = {
        headCommit = {
          nodes = {
            {
              commit = {
                statusCheckRollup = {
                  contexts = {
                    nodes = {
                      -- Two runs of "lint" — keep the latest startedAt.
                      ctx('lint', 'FAILURE', '2026-06-12T10:00:00Z', 100),
                      ctx('lint', 'SUCCESS', '2026-06-12T12:00:00Z', 101),
                      -- Skipped: drop entirely.
                      ctx('skipped-job', 'SKIPPED', '2026-06-12T11:00:00Z', 102),
                      -- Non-actions app: drop.
                      ctx('codecov', 'SUCCESS', '2026-06-12T11:00:00Z', 103, { slug = 'codecov' }),
                      -- Non-CheckRun typename: drop.
                      ctx('status-context', 'SUCCESS', '2026-06-12T11:00:00Z', 104, { typename = 'StatusContext' }),
                      -- Malformed detailsUrl (no /actions/runs/.../job/...): drop.
                      {
                        __typename = 'CheckRun',
                        name = 'orphan',
                        conclusion = 'SUCCESS',
                        status = 'COMPLETED',
                        startedAt = '2026-06-12T11:00:00Z',
                        detailsUrl = 'https://github.com/o/r/something-else',
                        checkSuite = { app = { slug = 'github-actions' } },
                      },
                      -- In-progress (no conclusion). Should still show up.
                      ctx('build', nil, '2026-06-12T13:00:00Z', 200, { status = 'IN_PROGRESS' }),
                      -- Plain success — used to verify sort.
                      ctx('test', 'SUCCESS', '2026-06-12T13:30:00Z', 201),
                    },
                  },
                },
              },
            },
          },
        },
      }

      local jobs = to_ci_jobs(node)

      -- Exactly 3 jobs survive: lint, build, test. (skipped/codecov/StatusContext/orphan dropped.)
      assert(#jobs == 3, ('expected 3 jobs, got %d'):format(#jobs))

      local by_name = {}
      for _, j in ipairs(jobs) do
        by_name[j.name] = j
      end

      -- lint deduped to the latest startedAt (databaseId=101, conclusion=success).
      assert(by_name.lint, 'lint missing')
      assert(by_name.lint.databaseId == 101, ('lint databaseId=%s'):format(by_name.lint.databaseId))
      assert(by_name.lint.runId == 777, ('lint runId=%s'):format(by_name.lint.runId))
      assert(by_name.lint.conclusion == 'success', ('lint conclusion=%s'):format(by_name.lint.conclusion))
      assert(by_name.lint.status == 'completed', ('lint status=%s'):format(by_name.lint.status))

      -- build is in-progress (no conclusion, lowercase status).
      assert(by_name.build.conclusion == nil, 'build should have nil conclusion')
      assert(by_name.build.status == 'in_progress', ('build status=%s'):format(by_name.build.status))
      assert(by_name.build.databaseId == 200)
      assert(by_name.build.runId == 777)

      -- test: plain success.
      assert(by_name.test.databaseId == 201)
      assert(by_name.test.runId == 777)

      -- Sort: by (conclusion or status), then name. So:
      --   "completed" (no — `status` only used when conclusion is nil) — actually sort key is `conclusion or status`.
      --   lint: "success", test: "success", build: "in_progress". Alphabetic on key:
      --   "in_progress" < "success", so build first; then lint, test alphabetic.
      assert(jobs[1].name == 'build', ('jobs[1]=%s'):format(jobs[1].name))
      assert(jobs[2].name == 'lint', ('jobs[2]=%s'):format(jobs[2].name))
      assert(jobs[3].name == 'test', ('jobs[3]=%s'):format(jobs[3].name))
    end)
  end)

  it('get_user returns nil when not logged in', function()
    n.exec_lua(function(tmpdir)
      -- Point `gh` at an empty config dir and unset any auth tokens so it has no active account.
      vim.fn.setenv('GH_CONFIG_DIR', tmpdir)
      vim.fn.setenv('GH_TOKEN', '')
      vim.fn.setenv('GITHUB_TOKEN', '')
      local user = require('guh.gh').get_user()
      assert(user == nil, ('expected nil, got %q'):format(tostring(user)))
    end, t.tmpname(true))
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
            assert(type(thread.end_line) == 'number', 'thread.end_line should be number')
            assert(
              type(thread.start_line) == 'number' or thread.start_line == nil,
              'thread.start_line should be number or nil'
            )
            assert(type(thread.url) == 'string', 'thread.url should be string')
            assert(type(thread.comments) == 'table', 'thread.comments should be table')
            assert(#thread.comments > 0, 'thread.comments should not be empty')
            for _, comment in ipairs(thread.comments) do
              assert(comment.id, 'comment.id missing')
              assert(type(comment.url) == 'string', 'comment.url should be string')
              assert(type(comment.path) == 'string', 'comment.path should be string')
              assert(type(comment.end_line) == 'number', 'comment.end_line should be number')
              assert(
                type(comment.start_line) == 'number' or comment.start_line == nil,
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

      -- Tests real PR data from Github. Mirrors the flow in pr.load_pr:
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
          local threads_by_path = require('guh.comments').to_threads(pr.raw_comments)
          assert_threads(threads_by_path)
          done = true
        end)
        assert(
          vim.wait(5000, function()
            return done
          end, 100),
          'get_pr_data timed out'
        )
      end

      test_get_pr_data_full()
    end)
  end)

  it('"dd" from a `commit/…` buffer resolves to its PR', function()
    local pr_num = 2
    local repo = 'justinmk/guh.nvim'

    local commit_buf = n.exec_lua(function(pr_num_, repo_)
      local gh = require('guh.gh')
      local state = require('guh.state')

      -- Load PR so state.bufs.pr has a `pr_data` with commits (needed by resolve_pr).
      local done = false
      gh.get_pr_data(pr_num_, repo_, { force = true }, function(pr_data)
        assert(pr_data, 'get_pr_data returned nil')
        local pr_buf = state.init_buf('pr', true, repo_, pr_num_, { pr_data = pr_data })
        assert(vim.b[pr_buf].guh.pr_data.commits[1], 'pr_data.commits is empty')
        done = true
      end)
      assert(
        vim.wait(15000, function()
          return done
        end, 100),
        'get_pr_data timed out'
      )

      -- Open a `commit/…` buffer via `:Guh <sha>`.
      local pr_buf = state.get_buf('pr', repo_, pr_num_)
      local sha = vim.b[pr_buf].guh.pr_data.commits[1].oid
      vim.cmd('Guh ' .. sha)
      assert(
        vim.wait(15000, function()
          local b = state.get_buf('commit', repo_, sha, false)
          return b and vim.api.nvim_get_current_buf() == b
        end, 100),
        ':Guh <sha> timed out'
      )
      assert(vim.b.guh.feat == 'commit', 'feat != commit')
      return vim.api.nvim_get_current_buf()
    end, pr_num, repo)

    -- "dd" should return to the "prdiff/…" buffer.
    n.feed('dd')

    t.retry(nil, 10000, function()
      local has_prdiff = n.exec_lua(function(pr_num_, repo_)
        return require('guh.state').get_buf('prdiff', repo_, pr_num_, false) ~= nil
      end, pr_num, repo)
      assert(has_prdiff, 'prdiff buf was not created')
    end)

    -- Now :bwipeout the PR buf, then confirm that "dd" shows an error.
    n.exec_lua(function(pr_num_, repo_, commit_buf_)
      local state = require('guh.state')
      vim.cmd('bwipeout! ' .. assert(state.get_buf('pr', repo_, pr_num_, false)))
      vim.api.nvim_set_current_buf(commit_buf_)
      local ok, err = pcall(require('guh.pr').show_pr_diff)
      assert(not ok, 'expected show_pr_diff to error')
      assert(err:match('Failed to resolve PR id'), ('error: %s'):format(err))
    end, pr_num, repo, commit_buf)
  end)
end)

describe('comments', function()
  it('prepare_to_comment (hardcoded diff)', function()
    n.exec_lua(function()
      local comments = require('guh.comments')
      local state = require('guh.state')

      local pr_id = 42
      local buf = state.init_buf('prdiff', false, 'justinmk/guh.nvim', pr_id)

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

      local info = comments.prepare_to_comment(buf, 9, 9)
      assert(info)
      assert('lua/guh/config.lua' == info.file)
      assert(16 == info.start_line, info.start_line)
      assert(16 == info.end_line, info.end_line)
    end)
  end)

  it('comments.show anchors LEFT-side (deleted-line) comments', function()
    n.exec_lua(function()
      local comments = require('guh.comments')
      local state = require('guh.state')

      local pr_id = 99
      local repo = 'justinmk/guh.nvim'
      local diff_buf = state.init_buf('prdiff', false, repo, pr_id)

      -- Synthetic unified diff. Row numbers are 1-indexed.
      --   row 6 ` context` → old=10, new=10
      --   row 7 `-deleted` → old=11           (LEFT side only)
      --   row 8 ` tail`    → old=12, new=11
      vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, {
        'diff --git a/f.lua b/f.lua',
        'index 000..111 100644',
        '--- a/f.lua',
        '+++ b/f.lua',
        '@@ -10,3 +10,2 @@',
        ' context',
        '-deleted',
        ' tail',
      })

      --- @type table<string, CommentThread[]>
      local threads = {
        ['f.lua'] = {
          -- LEFT (deleted-line) comment: must resolve to row 7 (the '-' row).
          {
            id = 1,
            end_line = 11,
            start_line = 11,
            url = '',
            comments = {
              {
                id = 1,
                user = 'alice',
                body = 'hi',
                updated_at = '2024-01-01',
                side = 'LEFT',
                end_line = 11,
                path = 'f.lua',
              },
            },
          },
          -- RIGHT (new-side) comment: control — must resolve to row 6.
          {
            id = 2,
            end_line = 10,
            start_line = 10,
            url = '',
            comments = {
              {
                id = 2,
                user = 'bob',
                body = 'yo',
                updated_at = '2024-01-01',
                side = 'RIGHT',
                end_line = 10,
                path = 'f.lua',
              },
            },
          },
        },
      }

      comments.load_pr_comments(pr_id, repo, diff_buf, { viewed = {}, n_threads = 0, n_resolved = 0 }, threads, 0, 0)

      local prc = state.get_buf('prcomments', repo, pr_id)
      local rows = vim.api.nvim_buf_get_lines(prc, 0, -1, false)
      -- Row 6 = ' context' (new=10) → RIGHT (bob) heading lands here.
      assert(rows[6] and rows[6]:match('^▎ .*bob'), ('row 6: %q'):format(rows[6] or '<nil>'))
      -- Row 7 = '-deleted' (old=11) → LEFT (alice) heading lands here. This is the regression check.
      assert(rows[7] and rows[7]:match('^▎ .*alice'), ('row 7: %q'):format(rows[7] or '<nil>'))
    end)
  end)

  it('update_comment opens edit buf prefilled with the existing body', function()
    n.exec_lua(function()
      local comments = require('guh.comments')
      local state = require('guh.state')

      local pr_id = 77
      local repo = 'justinmk/guh.nvim'
      local diff_buf = state.init_buf('prdiff', false, repo, pr_id)

      vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, {
        'diff --git a/f.lua b/f.lua',
        'index 000..111 100644',
        '--- a/f.lua',
        '+++ b/f.lua',
        '@@ -10,1 +10,2 @@',
        ' context', -- row 6: new=10
        '+added', -- row 7: new=11
      })

      --- @type table<string, CommentThread[]>
      local threads = {
        ['f.lua'] = {
          {
            id = 999,
            end_line = 10,
            start_line = 10,
            url = '',
            comments = {
              {
                id = 12345,
                user = 'alice',
                body = 'original body',
                updated_at = '2024-01-01',
                side = 'RIGHT',
                end_line = 10,
                path = 'f.lua',
              },
            },
          },
        },
      }

      comments.load_pr_comments(pr_id, repo, diff_buf, { viewed = {}, n_threads = 0, n_resolved = 0 }, threads, 0, 0)
      -- `load_pr_comments` doesn't show the buf; focus it so `update_comment` reads its `b:guh`.
      local prc_buf = assert(state.get_buf('prcomments', repo, pr_id, false))
      vim.api.nvim_set_current_buf(prc_buf)

      -- Row 6 is the heading of alice's comment (anchored to ' context', new=10).
      comments.update_comment(6)

      -- The 'comment' edit buf must exist and contain the comment's body.
      local edit_buf = assert(state.get_buf('comment', repo, pr_id, false))
      local lines = vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false)
      assert(#lines == 1 and lines[1] == 'original body', vim.inspect(lines))
    end)
  end)
end)

describe(':Guh', function()
  it('shows error if not logged-in', function()
    n.exec_lua(function(tmpdir)
      vim.fn.setenv('GH_CONFIG_DIR', tmpdir)
      vim.fn.setenv('GH_TOKEN', '')
      vim.fn.setenv('GITHUB_TOKEN', '')
      local captured
      vim.notify = function(msg, level)
        captured = { msg = msg, level = level }
      end
      require('guh.pr').select({ args = '1' })
      vim.wait(1000, function()
        return captured ~= nil
      end, 20)
      assert(captured, 'vim.notify() was not called')
      assert(captured.msg:match('[Nn]ot logged in'), ('msg: %q'):format(captured.msg))
      assert(captured.level == vim.log.levels.ERROR, ('level: %s'):format(tostring(captured.level)))
    end, t.tmpname(true))
  end)

  it('"dd" loads PR diff + comments split window', function()
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

    -- Note: "Viewed" state is per-user, so we can't assert (N/M viewed) or (viewed) rows.
    -- Row 1 is the 'winbar'.
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

  it('":Guh 1" shows pr/, eagerly loads prdiff/ in background', function()
    n.command('Guh 1')

    -- curwin shows the pr/ buf; prdiff/ is loaded but not displayed.
    screen:expect {
      timeout = 15000,
      attr_ids = {}, -- Don't care about colors.
      grid = [[
        {MATCH:.*}|*8
        {MATCH:.*guh://.*/pr/1.*}|
        {MATCH:.*}|
      ]],
    }
    -- prdiff/ buf exists in state.bufs even though it's not displayed.
    local has_prdiff = n.exec_lua(function()
      local state = require('guh.state')
      local buf = state.get_buf('prdiff', vim.b.guh.repo, vim.b.guh.id, false)
      return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
    end)
    assert(has_prdiff, 'prdiff/ buf should be eagerly loaded')
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
    t.eq({ owner = 'neovim', repo = 'neovim', id = 24, is_pr = false }, parse_target('guh://neovim/neovim/issue/24'))

    t.eq(nil, parse_target('garbage'))
    t.eq(nil, parse_target(''))
    t.eq({ owner = 'owner', repo = 'repo' }, parse_target('owner/repo'))
    t.eq({ owner = 'owner', repo = 'repo' }, parse_target('https://github.com/owner/repo'))
    t.eq({ owner = 'owner', repo = 'repo' }, parse_target('https://github.com/owner/repo/'))
  end)
end)
