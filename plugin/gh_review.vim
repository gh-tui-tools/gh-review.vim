vim9script

# gh-review.vim — GitHub PR code review plugin for Vim 9.0+

if exists('g:loaded_gh_review')
  finish
endif
g:loaded_gh_review = true

if !has('vim9script') || v:versionlong < 9000000
  echohl ErrorMsg
  echomsg 'gh-review.vim requires Vim 9.0+'
  echohl None
  finish
endif

# --- Commands ---

command! -nargs=? GHReview gh_review#Open(<q-args>)
command! -nargs=0 GHReviewFiles gh_review#ToggleFiles()
command! -nargs=0 GHReviewStart gh_review#StartReview()
command! -nargs=0 GHReviewSubmit gh_review#SubmitReview()
command! -nargs=0 GHReviewDiscard gh_review#DiscardReview()
command! -nargs=0 GHReviewClose gh_review#Close()

# --- Signs ---

sign define gh_review_thread text=CT texthl=GHReviewThread linehl=NONE
sign define gh_review_thread_resolved text=CR texthl=GHReviewThreadResolved linehl=NONE
sign define gh_review_thread_pending text=CP texthl=GHReviewThreadPending linehl=NONE

# --- Highlight groups ---

highlight default GHReviewThread ctermfg=Blue guifg=#58a6ff
highlight default GHReviewThreadResolved ctermfg=Green guifg=#3fb950
highlight default GHReviewThreadPending ctermfg=Yellow guifg=#d29922
highlight default GHReviewVirtText ctermfg=Gray guifg=#8b949e cterm=italic gui=italic

# --- Fold guard for diff buffers ---
# Plugins (LSP, linters, etc.) may asynchronously override foldmethod on
# diff buffers.  Restore it whenever that happens.

augroup gh_review_fold_guard
  autocmd!
  autocmd OptionSet foldmethod if get(b:, 'gh_review_diff', false) && &foldmethod !=# 'diff' | noautocmd setlocal foldmethod=diff foldlevel=0 | endif
  autocmd OptionSet foldenable if get(b:, 'gh_review_diff', false) && !&foldenable | noautocmd setlocal foldenable | endif
augroup END
