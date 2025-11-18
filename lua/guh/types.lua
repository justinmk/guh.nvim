--- @alias Feat 'diff'|'logs'|'pr'|'issue'|'comment'|'comments'|'status'

--- @class BufState
--- Buffer-local b:guh dict.
--- @field id? integer PR or issue number
--- @field feat? Feat Feature name
--- @field pr_data? PullRequest

--- @class Comment
--- @field body string
--- @field diff_hunk string
--- @field id number
--- @field line number
--- @field path string
--- @field start_line number
--- @field updated_at string
--- @field url string
--- @field user string

--- @class GroupedComment
--- @field comments Comment[]
--- @field content string
--- @field id number
--- @field line number
--- @field start_line number
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

--- @class PullRequest
--- @field author table
--- @field baseRefName string
--- @field baseRefOid string
--- @field body string
--- @field changedFiles number
--- @field comments Comment[]
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
