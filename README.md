# guh.nvim (ghlite.nvim fork)

> [!NOTE]
> This plugin is pretty sweet, but still WIP/beta. PRs/feedback welcome!

Work with GitHub PRs in Neovim. Wraps the GitHub `gh` CLI with a minimalist yet
effective workflow.

## Usage

Run `:Guh` to see status.

    :Guh

Run `:Guh 42` to view PR or issue 42. Also accepts a GitHub URL or
`owner/repo#123` slug:

    :Guh 42
    :Guh https://github.com/justinmk/guh.nvim/pull/13
    :Guh neovim/neovim#20632
    :Guh guh://pr/justinmk/guh.nvim/2

Inside any `guh://` buffer, press `<CR>` to run `:Guh` on the target at cursor.

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
- nvim 0.12+
- ["gh" (GitHub CLI)](https://cli.github.com/)

## How it works

1. Shows `gh` output in a `:terminal` buffer.
2. Sets global `<Plug>(guh-…)` keymaps. Provides default buffer-local mappings
   if you don't set any mappings to the `<Plug>` mappings.
3. `:Guh` is the main entrypoint. It shows status, or views a given item (PR, issue).
4. Presents PR diff comments in a 'scrollbind' split window.
5. Loads most-recent CI logs for all "jobs" in the CI matrix.
6. (TODO) Show PR comments as Nvim "diagnostics".
7. (TODO) Fetch the git data into `.git` (without doing a checkout).
8. (TODO) When viewing the diff, user can navigate to the git object (file)
   without doing a checkout.
9. (TODO) PR comments will display on relevant git objects.

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
