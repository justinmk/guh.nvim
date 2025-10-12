# guh.nvim (ghlite.nvim fork)

> W.I.P. Fork of https://github.com/daliusd/ghlite.nvim

Work with GitHub PRs in Neovim. Wraps the GitHub `gh` CLI with a minimalist yet
effective workflow.

## Usage

Run `:Guh` to see status.

    :Guh

Run `:Guh 42` to view PR or issue 42.

    :Guh 42

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

1. Show `gh` output in a `:terminal` buffer.
2. Set keymaps on the buffer.
3. PR diff comments are loaded in a 'scrollbind' split window.
4. (TODO) Fetch the git data into `.git` (without doing a checkout).
5. (TODO) When viewing the diff, user can navigate to the git object (file)
   without doing a checkout.
6. (TODO) PR comments will display on relevant git objects.

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
