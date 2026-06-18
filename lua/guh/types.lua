--- @alias Feat 'comment'|'commit'|'edit'|'issue'|'merge'|'pr'|'prcomments'|'prdiff'|'prlogs'|'review'|'status'

--- Function "cmd" for `util.run_term_cmds`. Not added to `b:guh.jobs` (not cancellable), so must check buffer validity.
--- @alias TermCmdFn fun(buf: integer, on_stdout: fun(_: any, data: string[]), on_stderr: fun(_: any, data: string[])?, on_exit: fun())

--- Command for `util.run_term_cmds` command: a shell argv, or a `TermCmdFn`.
--- @alias TermCmd string[]|TermCmdFn

--- @class Notification A `b:guh.notifications` entry (keyed by slug "owner/repo#NNN").
--- @field thread_id string GitHub notification thread-id (for mark-as-read/done).
--- @field is_pr boolean Lets `pr.select` skip its PR-vs-issue probe.

--- @class BufState
--- Buffer-local b:guh dict.
--- @field chan? integer Channel-id for `run_term_cmds` or other terminal-buffers.
--- @field jobs? integer[] In-flight jobs for the current `run_term_cmds` run.
--- @field feat? Feat Feature name
--- @field id? integer|string PR or issue number, or commit SHA.
--- @field pr_data? PullRequest
--- @field repo? string "owner/name"
--- @field notifications? table<string, Notification> Unread notifications on `guh://status` (keyed by slug).

--- @class Comment
--- @field body string
--- @field diff_hunk string
--- @field end_line number End of comment range (1-indexed GitHub file-line). Falls back to `originalLine` for LEFT-side / outdated threads (those have no current-HEAD `line`).
--- @field end_bufline? integer End of _rendered_ comment range (1-indexed "prdiff" buffer-line). See `start_bufline`.
--- @field id number
--- @field path string For `outdated`: a synthetic key `outdated-<thread_id>:<real_path>`.
--- @field side? 'LEFT'|'RIGHT' Diff side the comment anchors to. LEFT = deleted-line/old file, RIGHT = added/context/new file.
--- @field start_line number Start of comment range (1-indexed GitHub file-line). Falls back to `originalStartLine` for LEFT-side / outdated threads.
--- @field start_bufline? integer Start of _rendered_ comment range (1-indexed "prdiff" buffer-line). Set at render time.
--- @field updated_at string
--- @field url string
--- @field user string
--- @field outdated? boolean true if the thread is outdated (line no longer in HEAD).
--- @field thread_id? number GraphQL thread id (root comment databaseId).
--- @field thread_node_id? string GraphQL global node id of the thread (e.g. `PRRT_kw…`). Needed by the resolveReviewThread mutation.

--- @class CommentThread
--- @field comments Comment[]
--- @field id number
--- @field end_line number End of thread range (1-indexed GitHub file-line). = head comment's `end_line`.
--- @field start_line number Start of thread range (1-indexed GitHub file-line).
--- @field url string

--- @class FileNameAndLinePair
--- @field [1] string filename
--- @field [2] number line

--- @class Issue
--- @field author table
--- @field body string
--- @field createdAt string
--- @field labels table
--- @field number number
--- @field state string
--- @field title string
--- @field updatedAt string
--- @field url string

--- @class PRCommit
--- @field oid string
--- @field messageHeadline string
--- @field messageBody string
--- @field authors table[]

--- @class CIJob A GitHub Actions check-run summary (one matrix-expanded job at the PR's head commit).
--- @field databaseId integer Workflow job id (parsed from `detailsUrl`), feeds `gh.get_pr_ci_logs`.
--- @field runId integer Workflow run id (parsed from `detailsUrl`), feeds `gh run rerun`.
--- @field name string
--- @field conclusion? string lowercase: "success", "failure", "cancelled", … (nil if in-progress).
--- @field status? string lowercase: "completed", "in_progress", "queued", …
--- @field startedAt? string
--- @field url? string Web URL of the job (`detailsUrl`).

--- @class PullRequest PR data selected from GraphQL by `gh.get_pr_data`.
--- @field node_id string GraphQL global node id (e.g. `PR_kw…`). Needed by mutations like `markFileAsViewed`.
--- @field author table
--- @field baseRefName string
--- @field baseRefOid string
--- @field body string
--- @field changedFiles number
--- @field ci_jobs CIJob[] Latest matrix-expanded github-actions jobs at the head commit (sorted by status, name).
--- @field commits PRCommit[]
--- @field createdAt string
--- @field headRefName string
--- @field headRefOid string
--- @field isDraft boolean
--- @field labels table
--- @field number number
--- @field reviewDecision string
--- @field reviews table
--- @field title string
--- @field url string
--- @field raw_comments Comment[] Flat per-comment list from `flatten_review_threads`.
--- @field viewed table<string, boolean> Per-file "Viewed" flag.
--- @field file_paths table<string, true> Set of all current paths in this PR's diff. Used to validate `markFileAsViewed` targets locally.
--- @field n_files? integer Files in the rendered diff (incl. outdated/outside virtual files). Set by `pr.load_pr`.
--- @field n_resolved integer Resolved review-thread count.
--- @field n_threads integer Total review-thread count (resolved + unresolved).
--- @field n_viewed_threads? integer Unresolved threads hidden in "Viewed" files. Set by `pr.load_pr`.
--- @field diff_stdout? string Cached raw `gh pr diff` output. Set by `pr.load_pr`.
