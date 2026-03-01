# gh-review.vim Design

## Overview

gh-review.vim is a Vim 9.0+ plugin for reviewing GitHub pull requests entirely within Vim. It is the Vim counterpart to [gh-review.nvim](https://github.com/gh-tui-tools/gh-review.nvim); the two plugins share a common design, each implemented idiomatically for its editor. gh-review.vim provides side-by-side diffs, review thread viewing and commenting, commit suggestions, and review submission — all driven by the `gh` CLI and the GitHub GraphQL/REST APIs.

### Scope

The goal of this plugin is to provide the simplest means possible for performing GitHub PR reviews. Anything beyond that is a non-goal — for example, providing any means for dealing with GitHub Issues, Notifications, Discussions, or Actions/Workflows, or even providing any means for other PR-related tasks such as browsing lists of PRs or managing labels, assignees, or requested reviewers. The user is expected to perform those tasks using other tooling.

This plugin is intentionally targeted at the use case where a user has already identified a specific PR or PR branch they are ready to review.

## Workflows

The plugin is designed around two main workflows that reflect different user roles and intent.

### Checkout workflow

The user is in a clone of the PR’s repo (or has already checked out the PR branch). They run `:GHReview` with no argument, `:GHReview <number>`, or `:GHReview <URL>` where the URL refers to the same repo.

- If the user is already on the PR branch (detected by comparing the current branch name against the PR’s head ref), the plugin skips straight to loading the UI with no checkout prompt.
- If the user is on a different branch but the repo matches, the plugin prompts: “Check out branch feature-x? (Y/n)”. On “Yes”, the branch is fetched via `git fetch origin pull/N/head` and checked out with `git checkout -B`. Push tracking is configured automatically (origin for same-repo PRs; a new remote for fork PRs, matching the SSH/HTTPS protocol of origin).
- If the user declines the checkout, or the checkout fails (e.g., dirty working tree), the plugin falls back to the no-checkout workflow below.
- When checked out, the right/head diff buffer is **editable** — the user can modify files locally and save with `:w`, which writes directly to the working tree. The user can `git push` to push changes back to the PR branch.

### No-checkout workflow

The user may not be in the repo’s clone directory at all, or may be reviewing a PR from a different repo. They run `:GHReview <URL>` where the URL refers to a different repo than the current working directory. This workflow also activates as a fallback when the user declines a checkout or when a checkout fails.

- The plugin detects that the URL’s owner/repo does **not** match the local origin remote (or there is no git repo at all). No checkout is offered or attempted.
- All diff content is fetched via `git show` (falling back to GraphQL blob queries if the ref is not available locally).
- The right/head diff buffer is **read-only** (`buftype=nofile`, `nomodifiable`).
- The user can still add comments, commit suggestions, and manage reviews through the GitHub API.

The checkout workflow is typically used by a project maintainer reviewing a contributor’s PR — they check out the branch so they can make edits, commit fixes, and push directly. The no-checkout workflow is more typical of a non-maintainer reviewer who only needs to read the diff and leave comments.

### What differs between the workflows

| Capability                       | Checkout        | No checkout |
|----------------------------------|-----------------|-------------|
| Right/head buffer                | Editable (`buftype=acwrite`) | Read-only |
| `:w` writes to working tree      | Yes             | No          |
| External change detection        | Yes (mtime tracking) | N/A    |
| Push changes to PR branch        | Yes (`git push`) | No         |
| Jump to file from diff (`gF`)    | Yes             | No          |
| Add review comments              | Yes             | Yes         |
| Commit suggestions (`gs`)        | Yes             | Yes         |
| Resolve/unresolve threads        | Yes             | Yes         |
| Start/submit/discard reviews     | Yes             | Yes         |

The `state.IsLocalCheckout()` flag controls this distinction. It is set to `true` when the branch is checked out (or was already checked out), and `false` otherwise. `SetupDiffBuffer()` checks this flag to decide whether the right buffer is editable or read-only.

## Architecture

### Module structure

```
plugin/gh_review.vim          Entry point: commands, signs, highlights, fold guard
autoload/gh_review.vim        Top-level orchestration (Open, Close, review lifecycle)
autoload/gh_review/
  api.vim                     Async wrapper around the gh CLI
  graphql.vim                 GraphQL query/mutation constants
  state.vim                   Centralized state management
  files.vim                   Changed files list buffer
  diff.vim                    Side-by-side diff view with signs
  thread.vim                  Thread/comment buffer for viewing and replying
syntax/
  gh-review-files.vim         Syntax highlighting for the files list
  gh-review-thread.vim        Syntax highlighting for the thread buffer
```

### State management (`state.vim`)

All plugin state lives in script-local variables in `state.vim`, accessed through exported getter/setter functions. This includes:

- **PR metadata**: id, number, title, state, base/head refs and OIDs, head repository owner/name (guarded against null for deleted forks), merge base OID.
- **Repo info**: owner and name, detected from `git remote get-url origin` or provided via URL argument.
- **Changed files**: list of dicts with path, additions, deletions, changeType.
- **Review threads**: indexed by thread ID in a dict. Threads are the central data structure — they drive sign placement, files list thread counts, and the thread buffer content.
- **Buffer/window IDs**: files list, left diff, right diff, thread buffer and window.
- **UI state**: current diff path, local checkout flag, pending review ID.

`GetParticipants()` extracts unique, sorted `author.login` values from all thread comments, used by the thread buffer’s omnifunc for `@`-mention completion.

`Reset()` clears everything, called by `:GHReviewClose`.

### Async API layer (`api.vim`)

All external commands run asynchronously via `job_start()`:

- **`RunCmdAsync(cmd, Callback)`**: runs an arbitrary command. Callback receives `(stdout, stderr, exit_status)`.
- **`RunAsync(cmd, Callback)`**: prepends `gh` to the command. Callback receives `(stdout, stderr)`.
- **`GraphQL(query, variables, Callback)`**: builds the `gh api graphql` command with `-f`/`-F` flags (string vs. JSON), runs it, parses the response, checks for GraphQL errors, and calls back with the parsed dict.

All callbacks are deferred to the main loop via `timer_start(0, ...)` to avoid running inside job handler context.

### GraphQL queries (`graphql.vim`)

Constants for all API operations, using heredoc syntax (joined into strings since heredocs produce `list<string>` in Vim9script):

- `QUERY_PR_DETAILS`: fetches PR metadata, files (first 100), review threads (first 100) with comments (first 50), and pending reviews.
- `QUERY_REVIEW_THREADS`: lighter query for refreshing threads only.
- Mutations for: starting a review, submitting a review, creating and submitting a review in one step, adding a thread, replying to a thread, resolving/unresolving threads, deleting a review.

### Opening a PR (`gh_review.vim: Open()`)

The `Open()` function orchestrates the full startup sequence:

1. **Parse input**: accepts a PR number, a full GitHub PR URL, or nothing (auto-detect from current branch via `gh pr view`). URLs are parsed to extract owner, repo name, and PR number.

2. **Determine repo**: if a URL specifies a repo, use it; otherwise detect from `git remote get-url origin`. Sets `should_checkout` based on whether the URL’s repo matches the local origin.

3. **Fetch PR details**: GraphQL query for metadata, files, threads. Response is validated before use (guards against missing/empty data).

4. **Checkout decision**:
   - If already on the PR branch — skip straight to loading the UI.
   - If local repo matches — prompt to check out.
   - If different repo or user declines — set `is_local_checkout = false`.

5. **Checkout sequence** (when proceeding):
   - `git fetch origin pull/N/head` (via `RunCmdAsync`)
   - `git checkout -B <branch> FETCH_HEAD` (via `RunCmdAsync`)
   - `SetupPushTracking()` configures the branch’s remote and merge ref.
   - `LoadUI()` is called only **after** checkout completes (or fails), not in parallel with it.

6. **Load UI**: `FetchMergeBase()` then `files.Open()`.

### Merge base resolution (`FetchMergeBase()`)

Determines the correct merge base for accurate diffs:

1. Try `git merge-base origin/<base> origin/<head>` locally.
2. If that fails, fall back to the REST API compare endpoint.
3. If both fail, use the base OID as a last resort (with a warning that the diff may be inaccurate).

Doing this after checkout is intentional — the fetch brings down the refs, making the local `git merge-base` more likely to succeed.

### Push tracking (`SetupPushTracking()`)

Configures `git push` to work correctly after checkout:

- **Same-repo PRs**: sets the branch’s remote to `origin`.
- **Fork PRs**: adds a remote for the fork (named after the fork owner), matching the SSH/HTTPS protocol of `origin`. Sets the branch’s remote to the fork remote and merge ref to the fork’s branch.

Each git command checks `v:shell_error` and warns on failure.

### Files list (`files.vim`)

A bottom split showing changed files with diff stats and thread counts:

```
https://github.com/owner/repo/pull/123: Fix the widget
Files changed (3)

  +12 -3   M  src/main.rs         [2 threads]
  +45 -0   A  src/new_file.rs
  +0  -22  D  src/old_file.rs
```

- Opens in a `botright` split, 12 lines high, with `winfixheight`.
- Buffer type is `nofile` with `bufhidden=hide` (content survives when the window is closed and reopened via toggle).
- `<CR>` opens the side-by-side diff for the file under the cursor.
- `R` refreshes threads from GitHub and rerenders.
- `q` / `gf` closes the files list.
- `g?` opens a popup showing available keymaps.
- When the files list closes, `wincmd =` equalizes window heights, then a scroll nudge (`Ctrl-E` / `Ctrl-Y`) in each diff window forces scrollbind viewports to update.

### Side-by-side diff (`diff.vim`)

Two vertically split buffers in Vim’s native diff mode:

- **Left buffer** (`gh-review://LEFT/<path>`): base version at the merge base commit. Always read-only.
- **Right buffer** (`gh-review://RIGHT/<path>`): head version at the PR’s head commit. Editable when `is_local_checkout` is true; read-only otherwise.

#### Content fetching

File content is fetched asynchronously, with a two-step fallback:

1. `git show <ref>:<path>` via `job_start()` (fast, works when refs are available locally).
2. GraphQL blob query via the GitHub API (works for cross-repo reviews where refs aren’t local).

Both sides are fetched in parallel. `ShowDiff()` is called via `timer_start(0, ...)` once both complete.

#### Editable buffers (checkout workflow)

When `is_local_checkout` is true, the right buffer is set up with:

- `buftype=acwrite` — Vim delegates `:w` to the `BufWriteCmd` autocmd.
- `BufWriteCmd` calls `WriteBuffer()`, which:
  - Writes buffer content to the working tree via `writefile()`.
  - Updates the stored mtime to prevent false external-change detection.
  - Echoes a confirmation message matching Vim’s native format.
- `FocusGained` / `BufEnter` / `CursorHold` autocmds call `CheckExternalChange()`, which:
  - Compares the file’s current mtime against the stored mtime.
  - If changed, prompts the user to reload (using `inputsave()` / `inputrestore()` to preserve typeahead in the autocmd context).
  - On reload, updates buffer content, runs `diffupdate`, and redraws.

#### Syntax highlighting

`SetupDiffBuffer()` sets `syntax=<lang>` based on the file extension, using `syntax=` instead of `filetype=` to avoid triggering FileType autocmds (which would cause LSP/linter plugins to attach). A map covers common extensions; unrecognized extensions fall through to the extension name itself.

#### Concealing

Syntax concealing (e.g., hiding markdown link URLs) works when `conceallevel` is set and the syntax file defines `conceal` rules. In practice, `foldmethod=diff` with closed folds can sometimes prevent concealing from rendering until folds are cycled.

`ShowDiff()` works around this by deferring a fold cycle after the initial render: open all folds (`zR`), force a `redraw`, then re-close all folds (`zM`). The redraw between open and close is essential — without it, the workaround has no effect. This runs via `timer_start(50, ...)` to let the initial diff render complete first.

#### Fold guard

Plugins (LSP, linters) may asynchronously override `foldmethod` on diff buffers. A global `OptionSet` autocmd in `plugin/gh_review.vim` restores `foldmethod=diff` whenever it changes on buffers marked with `b:gh_review_diff`.

#### Signs and virtual text

Review threads are indicated by signs in the sign column and virtual text at end-of-line:

- `CT` (blue, `GHReviewThread`) — normal thread (last comment state is `COMMENTED`).
- `CR` (green, `GHReviewThreadResolved`) — resolved thread.
- `CP` (yellow, `GHReviewThreadPending`) — thread with a pending review comment.

Each sign is accompanied by virtual text (via `prop_add` with `text` and `text_align: “after”`) showing the first comment’s author and a truncated body (up to 60 characters), highlighted with `GHReviewVirtText` (dim italic). This gives at-a-glance context without opening the thread.

`PlaceSigns()` iterates threads for the current file and places both signs and virtual text on the appropriate side (left or right buffer) at the thread’s line number. For outdated threads where `line` is null, it falls back to `originalLine`. Virtual text is guarded by a `bufloaded()` check and a `try`/`catch` since `prop_add` with `bufnr:` requires the target buffer to be loaded with content.

`RefreshSigns()` clears and replaces all signs and virtual text for the current diff path.

#### Floating thread preview

The `K` keymap opens a floating popup (`popup_atcursor` with border and padding) showing the full thread content at the cursor line. The preview is read-only and closes on `q`, `<Esc>`, or click outside. Only one preview can be open at a time (tracked in a script-local `preview_winid`). This is lighter than `gt` — no split, no reply area.

#### Help popup

The `g?` keymap opens a floating popup listing all available keymaps for the current buffer type. Each buffer type (diff, thread, files list) has its own help card. This provides keymap discoverability without external plugins — the Vim analogue to Neovim’s keymap `desc` fields and which-key.nvim integration.

#### Window-local statusline

Both diff windows display a window-local statusline (via `setwinvar(winid, “&statusline”, ...)`) showing `PR #N · path · base/head (short OID)`, providing persistent context about what’s being reviewed. This sets the local statusline for each window independently, leaving the global statusline unaffected.

#### Keymaps

| Key   | Action                                              |
|-------|-----------------------------------------------------|
| `gt`  | Open thread at cursor line                          |
| `gc`  | Create new comment (visual mode: multi-line)        |
| `gs`  | Create suggestion (right buffer only, visual: range) |
| `]t`  | Jump to next thread sign                            |
| `[t`  | Jump to previous thread sign                        |
| `K`   | Preview thread at cursor (floating popup)           |
| `gf`  | Toggle the files list                               |
| `gF`  | Go to file at cursor line (checkout only)           |
| `q`   | Close the diff view                                 |
| `g?`  | Show keymap help                                    |

### Thread buffer (`thread.vim`)

A horizontal split at the bottom for viewing and replying to threads:

```
Thread on src/main.rs:42  [Active]
────────────────────────────────────────────────────────────
  42 + │ let x = foo();
────────────────────────────────────────────────────────────

alice (2025-01-15):
  Looks good

── Reply below (Ctrl-S to submit, Ctrl-R to resolve, Ctrl-Q to cancel) ──

```

#### Layout

- Opens in a `botright` split, 15 lines high, with `winfixheight`.
- The header area (everything above the reply separator) is **read-only**, enforced by a `CursorMoved`/`CursorMovedI` autocmd that toggles `nomodifiable` based on cursor position relative to `b:gh_review_reply_start`.
- The reply area (below the separator) is editable.
- Buffer type is `acwrite` so `:w` submits the reply.

#### Code context

The thread buffer shows the code line(s) being commented on, pulled from the left or right diff buffer depending on the thread’s `diffSide`. Lines are prefixed with `+` (right/head) or `-` (left/base) and the line number. Multi-line threads show the full range from `startLine` to `line`.

#### Submitting replies

Three paths depending on context:

1. **New thread**: `addPullRequestReviewThread` mutation. If a pending review is active, the thread is attached to it.
2. **Reply with active review**: `addPullRequestReviewComment` mutation using the pending review ID.
3. **Standalone reply** (no pending review): first tries the REST API (`POST .../comments/<id>/replies`). If that fails (e.g., node ID not accepted), falls back to creating a temporary review, adding the comment, and immediately submitting it as `COMMENT`.

#### Keymaps

| Key      | Action                                       |
|----------|----------------------------------------------|
| `Ctrl-S` | Submit reply (works in normal and insert mode) |
| `Ctrl-R` | Toggle resolved/unresolved                   |
| `q`      | Close thread buffer                          |
| `Ctrl-Q` | Close thread buffer (works in insert mode)   |
| `g?`     | Show keymap help                             |

#### @-mention completion

The thread buffer sets `omnifunc=GHReviewThreadOmnifunc`, a global function that completes `@`-mentions from thread participants. `state.GetParticipants()` provides the candidate list. Users trigger completion with `Ctrl-X Ctrl-O` (standard Vim omni-completion). The omnifunc is defined as a global function (`def g:GHReviewThreadOmnifunc()`) because Vim9script `def` functions in autoloaded scripts cannot be referenced directly as option values.

### Prompts

User prompts use `popup_menu()` and `confirm()` instead of the legacy `inputlist()` and `input()`:

- **Submit review action**: `popup_menu([“Comment”, “Approve”, “Request changes”], ...)` with a title and border.
- **Discard confirmation**: `confirm()` with “Yes”/“No” buttons, defaulting to “No”.
- **Checkout confirmation**: `confirm()` for branch checkout.
- **External file reload**: `confirm()` for disk-change detection.

### Statusline component

`gh_review#Statusline()` returns an empty string when no review is active, or a summary like `PR #42 · reviewing · 4 threads`. Users can call this from their `statusline` expression.

### Review lifecycle

- **`:GHReviewStart`**: creates a pending review via `addPullRequestReview`. All subsequent comments and replies are attached to this review. This is optional — `:GHReviewSubmit` works without it.
- **`:GHReviewSubmit`**: prompts for action (Comment / Approve / Request changes) and optional body. If a pending review is active, submits it via `submitPullRequestReview`. If no pending review exists, creates and submits a review in one step via `addPullRequestReview` with an `event` parameter.
- **`:GHReviewDiscard`**: prompts for confirmation, then deletes the pending review and all its pending comments via `deletePullRequestReview`.

If a pending review already exists on the PR (from a previous session or the GitHub web UI), it is detected during `SetPR()` and reused.

### Window management

Closing the files list or thread buffer frees vertical space. The plugin:

1. Calls `wincmd =` to equalize window heights.
2. Visits each diff window and performs a scroll nudge (`Ctrl-E` / `Ctrl-Y`) to force Vim to recompute the visible area in scrollbind/diff mode. Without this nudge, the viewport shows blank space where the closed window was.

`:GHReviewClose` tears down everything: closes the thread buffer, diff view, and files list; wipes all `gh-review://` buffers; resets state.

## Testing

Tests run in headless Vim (`vim --clean --not-a-term -N`) and use a custom `RunTest()` harness that captures `v:errors` after each test function. Test files:

| File                  | Coverage                                        |
|-----------------------|-------------------------------------------------|
| `test_state.vim`      | State setters/getters, SetPR, threads, reset, GetParticipants, Statusline |
| `test_diff_logic.vim` | Sign placement, sign types, virtual text, mtime tracking |
| `test_ui.vim`         | Files list rendering, toggle, close, keymaps    |
| `test_thread.vim`     | Thread buffer rendering, metadata, close, omnifunc |
| `test_navigation.vim` | Sign placement across sides, refresh, edge cases |
| `test_graphql.vim`    | GraphQL constant structure validation           |
| `test_open.vim`       | URL/number parsing                              |

Headless Vim constraints:
- `startinsert` crashes in `--not-a-term` mode; tests pass body content directly to `OpenNew()` instead.
- `bufhidden=hide` is needed to keep buffer content alive when switching windows.
- `<SID>` does not expand inside Vim9script `def` functions; the SID is captured at script level via `const SID = expand('<SID>')`.
