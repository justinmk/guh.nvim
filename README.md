# guh.nvim

> [!NOTE]
> This plugin is pretty sweet, but still WIP/beta. PRs/feedback welcome!

Work with GitHub PRs in Neovim. Wraps the GitHub `gh` CLI with a minimalist yet
effective workflow.

Guh is ~2k lines of code, leveraging builtin Nvim mechanisms such as diagnostics
and 'scrollbind' buffers, and otherwise delegating to the `gh` CLI.

## Usage

Run `:Guh` to see status.

    :Guh

Run `:Guh 42` to view PR/issue 42. Also accepts a GitHub URL, `owner/repo#123`
slug, or commit-id (SHA):

    :Guh 35951
    :Guh a1b2c3d
    :Guh https://github.com/neovim/neovim/pull/35951
    :Guh neovim/neovim#35951
    :Guh guh://neovim/neovim/pr/35951
    :Guh https://github.com/neovim/neovim/commit/a1b2c3d

Inside any `guh://` buffer, press `<Enter>` to run `:Guh` on the target at cursor.

Editable buffers (comments, merge message) confirm the action on
write-and-close:

- `:wq` (or `ZZ`) submits.
- `:q!` (or `ZQ`) discards.

See help file for details.

## Install

```lua
vim.pack.add{ 'https://github.com/justinmk/guh.nvim' }
```

See help for default config.

Requirements:
- nvim 0.13+
- ["gh" (GitHub CLI)](https://cli.github.com/)
- For working with Git, use any Git plugin such as [vim-fugitive](https://github.com/tpope/vim-fugitive).
- For highlighting diffs, use a plugin such as [diffs.nvim](https://github.com/barrettruth/diffs.nvim).

## How it works

1. Shows `gh` output in a `:terminal` buffer.
2. Sets global `<Plug>(guh-…)` keymaps. Provides default buffer-local mappings
   if you don't set any mappings to the `<Plug>` mappings.
3. `:Guh` is the main entrypoint. It shows status, or views a given item (PR, issue).
4. PR diff comments are presented:
    - in a 'scrollbind' split window
    - as "diagnostics" (`vim.diagnostic`), loaded in quickfix
5. Work with comments:
    - Create
    - Update
    - (TODO) Resolve
6. PR files marked as "Viewed" are collapsed to a `(viewed) <path>` line.
   The diff overlay shows `(N/M viewed)`.
    - (TODO) Set/reset the "Viewed" state of a file.
7. Loads most-recent CI logs for all "jobs" in the CI matrix.
8. (TODO) Fetch the git data into `.git` (without doing a checkout).
9. (TODO) When viewing the diff, user can navigate to the git object (file)
   without doing a checkout.
10. (TODO) PR comments will display on relevant *local* git objects.

## Development

Run the tests:

    NEOVIM_PATH='/path/to/neovim/' make test

Run specific tests:

    NEOVIM_PATH='/path/to/neovim/' make test TEST_FILTER=load_comments

## Related

- https://github.com/pwntester/octo.nvim

## Credits

guh.nvim was originally forked (and completely rewritten) from
https://github.com/daliusd/ghlite.nvim by Dalius Dobravolskas.
