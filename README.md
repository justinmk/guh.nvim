# guh.nvim

> [!NOTE]
> This plugin is pretty sweet, but still WIP/beta. PRs/feedback welcome!

Work with GitHub PRs in Neovim. Wraps the GitHub `gh` CLI with a minimalist yet
effective workflow.

Guh is ~2k lines of unimpeachable code, leveraging builtin Nvim mechanisms such as diagnostics
and 'scrollbind' buffers, and otherwise delegating to the `gh` CLI in a `:terminal` buffer.

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

Inside any `guh://` buffer, press `<Enter>` to run `:Guh` on the target at cursor. Hit `g?` to
review the keymaps.

When viewing a PR,

- Diff comments are presented (1) in a 'scrollbind' split, (2) as "diagnostics" (`vim.diagnostic`),
  (3) loaded in quickfix.
- Files marked as "Viewed" are collapsed to a `(viewed) <path>` line.
- You can view the most-recent CI logs for all "jobs" in the CI matrix.

Editable buffers (comments, merge message) confirm the action on write-and-close (`ZZ` submits, `ZQ`
discards).

Keymaps are provided as `<Plug>(guh-…)`. To customize, just define a mapping to the relevant
`<Plug>(guh-…)` and Guh will skip its default.

See [help file](./doc/guh.txt) for details.

## Install

```lua
vim.pack.add{ 'https://github.com/justinmk/guh.nvim' }
```

Requirements:

- Nvim 0.13+
- ["gh" (GitHub CLI)](https://cli.github.com/)
- (Optional) For working with Git, use a plugin such as [vim-fugitive](https://github.com/tpope/vim-fugitive).
- (Optional) For highlighting diffs, use a plugin such as [diffs.nvim](https://github.com/barrettruth/diffs.nvim).

## Related

- https://github.com/pwntester/octo.nvim

## Credits

guh.nvim was originally forked (and completely rewritten) from
https://github.com/daliusd/ghlite.nvim by Dalius Dobravolskas.
