# gh-review.vim

A Vim 9.0+ plugin for reviewing GitHub pull requests entirely within Vim.

Side-by-side diffs, review threads, code suggestions, and review submission — all driven by the `gh` CLI.

## Goal

This plugin — which is designed for the use case where you’ve already identified a specific PR or PR branch you’re ready to review — has just one single goal:

✅ provide the simplest means possible for performing a GitHub PR review within Vim

Anything beyond that is a non-goal — for example:

❌ GitHub Issues, Notifications, Discussions, or Actions/Workflows\
❌ Managing labels, assignees, or requested reviewers\
❌ Browsing or searching lists of PRs\
❌ Merging or closing PRs

You are expected to perform those tasks using other tooling (for example, [gh-dash](https://github.com/dlvhdr/gh-dash)).

## Requirements

- Vim 9.0 or later
- [`gh` CLI](https://cli.github.com), authenticated

## Installation

With Vim’s built-in package manager:

```sh
mkdir -p ~/.vim/pack/plugins/start
cd ~/.vim/pack/plugins/start
git clone https://github.com/gh-tui-tools/gh-review.vim.git
```

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'gh-tui-tools/gh-review.vim'
```

## Workflows

The plugin has two main workflows: A “checkout” workflow, and a “no-checkout” workflow.

### Checkout workflow

Typically used by a project maintainer reviewing a contributor’s PR. The branch is checked out locally so the reviewer can make edits, commit fixes, and push directly.

```vim
:GHReview 123          " PR number (checks out the branch)
:GHReview              " auto-detect from current branch
```

- The right/head diff buffer is editable — `:w` writes to the working tree.
- External file changes are detected and the plugin prompts to reload.
- `git push` pushes changes back to the PR branch (works for fork PRs too).

### No-checkout workflow

Typically used by a non-maintainer reviewer who only needs to read the diff and leave comments.

```vim
:GHReview https://github.com/owner/repo/pull/123
```

When the URL refers to a different repo than the current working directory, no checkout is attempted. The right/head diff buffer is read-only, but comments, suggestions, and review submission all work normally.

## Quick start

```
:GHReview 123           Open PR #123
<CR>                    Open a file’s side-by-side diff
]t / [t                 Jump between review threads
gt                      View a thread
gc                      Add a comment
:GHReviewSubmit         Submit a review
:GHReviewClose          Close all review buffers
```

## Commands

| Command            | Description                                                   |
|--------------------|---------------------------------------------------------------|
| `:GHReview`        | Open a PR (auto-detect, by number, or by URL)                 |
| `:GHReviewFiles`   | Toggle the changed files list                                 |
| `:GHReviewStart`   | Start a pending review (optional — `:GHReviewSubmit` works without it) |
| `:GHReviewSubmit`  | Submit a review (Comment / Approve / Request changes)         |
| `:GHReviewDiscard` | Discard the pending review and all its pending comments       |
| `:GHReviewClose`   | Close all review buffers and reset state                      |

## Diff mappings

| Key   | Action                                               |
|-------|------------------------------------------------------|
| `gt`  | Open the review thread at the cursor line             |
| `gc`  | Create a new comment (visual mode: multi-line)        |
| `gs`  | Create a suggestion (right buffer only, visual: range)|
| `]t`  | Jump to the next review thread                        |
| `[t`  | Jump to the previous review thread                    |
| `gf`  | Toggle the files list                                 |
| `q`   | Close the diff view                                   |

## Thread mappings

| Key      | Action                                        |
|----------|-----------------------------------------------|
| `Ctrl-S` | Submit the reply                              |
| `Ctrl-R` | Toggle resolved/unresolved                    |
| `q`      | Close the thread buffer                       |
| `Ctrl-Q` | Close the thread buffer (works in insert mode)|

## Signs

| Sign | Meaning                          |
|------|----------------------------------|
| `CT` | Comment thread (blue)            |
| `CR` | Resolved thread (green)          |
| `CP` | Pending review comment (yellow)  |

## Comparison with Neovim plugins

There does not appear to be any other existing Vim plugin for performing GitHub PR reviews. There are, however, Neovim plugins that provide PR review features — so the following table provides a feature comparison.

| Feature                          | gh-review.vim       | [gh.nvim][]         | [octo.nvim][]       |
|----------------------------------|---------------------|---------------------|---------------------|
| **Platform**                     | Vim 9.0+            | Neovim              | Neovim 0.10+        |
| **PR review: side-by-side diff** | Yes                 | Yes                 | Yes                 |
| **PR review: comments/threads**  | Yes                 | Yes                 | Yes                 |
| **PR review: code suggestions**  | Yes                 | No                  | Yes                 |
| **PR review: submit review**     | Yes                 | Yes                 | Yes                 |
| **PR review: resolve threads**   | Yes                 | Yes                 | Yes                 |
| **PR review: thread signs**      | Yes                 | No                  | No                  |
| **Editable diff buffers**        | Yes                 | Yes (via checkout)  | No                  |
| **External change detection**    | Yes                 | No                  | No                  |
| **Fork PR push tracking**        | Yes                 | Yes                 | No                  |
| **PR listing/browsing**          | No (non-goal)       | Yes                 | Yes                 |
| **Merge PRs**                    | No (non-goal)       | No                  | Yes                 |
| **Labels/assignees/reviewers**   | No (non-goal)       | No                  | Yes                 |
| **GitHub Issues**                | No (non-goal)       | Yes                 | Yes                 |
| **Notifications**                | No (non-goal)       | Yes                 | Yes                 |
| **Discussions**                  | No (non-goal)       | No                  | Yes                 |
| **Actions/Workflows**            | No (non-goal)       | No                  | Yes                 |
| **Reactions**                    | No (non-goal)       | No                  | Yes                 |
| **Dependencies**                 | `gh` CLI            | `gh` CLI, litee.nvim| `gh` CLI, plenary.nvim, picker |

[gh.nvim]: https://github.com/ldelossa/gh.nvim
[octo.nvim]: https://github.com/pwntester/octo.nvim

## Documentation

See `:help gh-review` for full documentation.

See [DESIGN.md](DESIGN.md) for architecture and implementation details.
