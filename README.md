# guh.nvim (ghlite.nvim fork)

> W.I.P. Fork of https://github.com/daliusd/ghlite.nvim

Work with GitHub PRs in Neovim. Wraps the GitHub `gh` CLI tool and provides
a very minimalist yet effective workflow.

## Install

    vim.pack.add{ 'https://github.com/justinmk/guh.nvim' }

See help for default config.

Requirements:
- nvim 0.12+
- ["gh" (GitHub CLI)](https://cli.github.com/)
- (Optional) [Diffview.nvim](https://github.com/sindrets/diffview.nvim)
- (Optional) To override UI select for fzf-lua or telescope, use:
  ```
  vim.cmd('FzfLua register_ui_select')
  ```

## Usage

See help file.

## Related

- https://github.com/pwntester/octo.nvim
