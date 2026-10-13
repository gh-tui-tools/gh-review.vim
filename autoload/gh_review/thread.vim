vim9script

# Thread/comment buffer for viewing and replying to review threads.

import autoload 'gh_review/state.vim'
import autoload 'gh_review/review.vim'
import autoload 'gh_review/api.vim'
import autoload 'gh_review/graphql.vim'
import autoload 'gh_review/diff.vim'
import autoload 'gh_review.vim' as orchestrator

# Action labels for the submit keys, derived from the pending-review state
# frozen when the thread buffer was opened.  Returns
# [default action (Ctrl-S / :w), alternative action (Ctrl-A)].
#
# There is no alternative in review mode: GitHub rejects standalone review
# comments and replies while the user has a pending review ("user_id can
# only have one pending review per pull request"), so Ctrl-A is not mapped.
def ModeLabels(pending_at_open: bool): list<string>
  if pending_at_open
    return ['add to pending review', '']
  endif
  return ['post comment now', 'start pending review']
enddef

def BuildSeparator(pending_at_open: bool): string
  var [default_label, alt_label] = ModeLabels(pending_at_open)
  var parts = ['Ctrl-S: ' .. default_label]
  if !empty(alt_label)
    add(parts, 'Ctrl-A: ' .. alt_label)
  endif
  add(parts, 'Ctrl-Q: cancel')
  return '── ' .. join(parts, ' · ') .. ' ──'
enddef

# Open an existing thread by id.
export def Open(thread_id: string)
  var t = state.GetThread(thread_id)
  if empty(t)
    echoerr '[gh-review] Thread not found: ' .. thread_id
    return
  endif
  ShowThread(t)
enddef

# Open a new comment thread (no existing comments yet).
export def OpenNew(path: string, start_line: number, end_line: number, side: string, initial_body: string = '')
  var pseudo_thread = {
    id: '',
    path: path,
    line: end_line,
    startLine: start_line == end_line ? v:null : start_line,
    diffSide: side,
    isResolved: false,
    comments: {nodes: []},
    _initial_body: initial_body,
  }
  ShowThread(pseudo_thread)
enddef

def ShowThread(t: dict<any>)
  # Close existing thread buffer if open
  CloseThreadBuffer()

  var path = get(t, 'path', state.GetDiffPath())
  var line_num = get(t, 'line', v:null)
  if line_num == v:null || type(line_num) != v:t_number || line_num <= 0
    line_num = get(t, 'originalLine', 0)
  endif
  var is_resolved = get(t, 'isResolved', false)
  var thread_id = get(t, 'id', '')
  var comments = get(get(t, 'comments', {}), 'nodes', [])
  var status_label = is_resolved ? 'Resolved' : 'Active'
  var is_new = empty(thread_id)

  # Freeze the submit mode for the whole lifetime of this buffer: the
  # separator labels and the meaning of Ctrl-S / Ctrl-A never change while
  # composing.  This uses the last known (display-only) review state so
  # opening stays instant; the actual review is resolved at submit time,
  # so a review started/submitted/discarded meanwhile only changes the
  # target, never which action runs.
  var pending_at_open = state.LastKnownReviewActive()

  # Build buffer content
  var lines: list<string> = []

  if is_new
    add(lines, printf('New comment on %s:%d  [New]', path, line_num))
  else
    add(lines, printf('Thread on %s:%d  [%s]', path, line_num, status_label))
  endif
  add(lines, repeat("─", 60))

  # Show code context (the line(s) being commented on)
  var side = get(t, 'diffSide', 'RIGHT')
  var context_bufnr = side ==# 'LEFT' ? state.GetLeftBufnr() : state.GetRightBufnr()
  if context_bufnr != -1 && bufexists(context_bufnr)
    var start_line = get(t, 'startLine', v:null)
    if start_line == v:null
      start_line = get(t, 'originalStartLine', v:null)
    endif
    var ctx_start = start_line != v:null ? start_line : line_num
    var ctx_end = line_num
    var prefix = side ==# 'LEFT' ? '-' : '+'
    var buf_lines = getbufline(context_bufnr, ctx_start, ctx_end)
    for i in range(len(buf_lines))
      add(lines, printf('  %d %s │ %s', ctx_start + i, prefix, buf_lines[i]))
    endfor
  endif

  add(lines, repeat("─", 60))
  add(lines, '')

  # Show existing comments
  for c in comments
    var author = get(get(c, 'author', {}), 'login', 'unknown')
    var created = FormatDate(get(c, 'createdAt', ''))
    add(lines, printf('%s (%s):', author, created))
    var body_lines = split(substitute(get(c, 'body', ''), "\r", '', 'g'), "\n")
    for bl in body_lines
      add(lines, '  ' .. bl)
    endfor
    var reaction_line = FormatReactions(c)
    if !empty(reaction_line)
      add(lines, reaction_line)
    endif
    add(lines, '')
  endfor

  # Reply separator (labels describe the frozen key meanings)
  add(lines, BuildSeparator(pending_at_open))
  add(lines, '')

  var reply_start = len(lines)

  var initial_body = get(t, '_initial_body', '')
  if !empty(initial_body)
    extend(lines, split(initial_body, "\n", true))
  endif

  # Create buffer in a horizontal split below the current window
  botright new
  resize 15
  var buf_name = 'gh-review://thread'
  var bufnr = bufnr(buf_name, true)
  execute 'buffer' bufnr
  state.SetThreadBufnr(bufnr)
  state.SetThreadWinid(win_getid())

  setlocal buftype=acwrite
  setlocal bufhidden=wipe
  setlocal noswapfile
  setlocal filetype=gh-review-thread
  setlocal signcolumn=no
  setlocal wrap
  setlocal winfixheight

  # Set the buffer content
  setlocal modifiable
  silent! deletebufline(bufnr, 1, '$')
  setbufline(bufnr, 1, lines)

  # Store metadata on the buffer
  b:gh_review_thread_id = thread_id
  b:gh_review_path = path
  b:gh_review_line = line_num
  b:gh_review_start_line = get(t, 'startLine', v:null)
  b:gh_review_side = side
  b:gh_review_reply_start = reply_start
  b:gh_review_is_new = is_new
  b:gh_review_is_resolved = is_resolved
  b:gh_review_pending_at_open = pending_at_open

  # Store the first comment's GraphQL node id (used as inReplyTo for
  # pending replies) and its numeric database id (needed for the REST
  # standalone-reply endpoint).
  if !empty(comments)
    b:gh_review_first_comment_id = comments[0].id
    var database_id = get(comments[0], 'databaseId', v:null)
    if database_id != v:null
      b:gh_review_first_comment_database_id = database_id
    endif
  endif

  # Make the header area read-only via autocmd
  augroup gh_review_thread
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> SubmitReply()
    autocmd CursorMoved,CursorMovedI <buffer> EnforceReadOnly()
  augroup END

  # Keymaps
  nnoremap <nowait> <buffer> <C-s> <ScriptCmd>SubmitReply()<CR>
  inoremap <nowait> <buffer> <C-s> <Esc><ScriptCmd>SubmitReply()<CR>
  if !pending_at_open
    nnoremap <nowait> <buffer> <C-a> <ScriptCmd>SubmitAlt()<CR>
    inoremap <nowait> <buffer> <C-a> <Esc><ScriptCmd>SubmitAlt()<CR>
  endif
  nnoremap <nowait> <buffer> <C-r> <ScriptCmd>ToggleResolve()<CR>
  nnoremap <nowait> <buffer> q <ScriptCmd>CloseThreadBuffer()<CR>
  nnoremap <nowait> <buffer> <C-q> <ScriptCmd>CloseThreadBuffer()<CR>
  inoremap <nowait> <buffer> <C-q> <Esc><ScriptCmd>CloseThreadBuffer()<CR>
  nnoremap <nowait> <buffer> g? <ScriptCmd>ShowThreadHelp()<CR>

  # @-mention completion via omnifunc
  setlocal omnifunc=GHReviewThreadOmnifunc

  # Position cursor at the reply area
  if !empty(initial_body)
    cursor(reply_start + 2, 1)
  else
    cursor(reply_start, 1)
    if is_new
      startinsert
    endif
  endif
enddef

def EnforceReadOnly()
  var reply_start = get(b:, 'gh_review_reply_start', 999999)
  if line('.') < reply_start
    setlocal nomodifiable
  else
    setlocal modifiable
  endif
enddef

def FormatDate(iso_date: string): string
  # "2024-01-15T10:30:00Z" -> "2024-01-15"
  return substitute(iso_date, 'T.*', '', '')
enddef

const REACTION_EMOJI: dict<string> = {
  THUMBS_UP: '👍',
  THUMBS_DOWN: '👎',
  LAUGH: '😄',
  HOORAY: '🎉',
  CONFUSED: '😕',
  HEART: '❤️',
  ROCKET: '🚀',
  EYES: '👀',
}

def FormatReactions(comment: dict<any>): string
  var groups = get(comment, 'reactionGroups', [])
  if type(groups) != v:t_list || empty(groups)
    return ''
  endif
  var parts: list<string> = []
  for g in groups
    var rtype = get(g, 'content', '')
    var cnt = get(get(g, 'reactors', {}), 'totalCount', 0)
    if cnt > 0
      var emoji = get(REACTION_EMOJI, rtype, rtype)
      add(parts, emoji .. ' ' .. cnt)
    endif
  endfor
  if empty(parts)
    return ''
  endif
  return '  ' .. join(parts, '  ')
enddef

def GetReplyText(): string
  var reply_start = get(b:, 'gh_review_reply_start', -1)
  if reply_start < 0
    return ''
  endif
  var lines = getbufline(state.GetThreadBufnr(), reply_start, '$')
  # Trim leading/trailing blank lines
  while !empty(lines) && trim(lines[0]) ==# ''
    remove(lines, 0)
  endwhile
  while !empty(lines) && trim(lines[-1]) ==# ''
    remove(lines, -1)
  endwhile
  return join(lines, "\n")
enddef

# Ctrl-S / :w — the contextual default action.
def SubmitReply()
  DispatchSubmit(get(b:, 'gh_review_pending_at_open', false))
enddef

# Ctrl-A — the alternative action ("start pending review").  Only mapped
# when the buffer was opened without a pending review.
def SubmitAlt()
  DispatchSubmit(!get(b:, 'gh_review_pending_at_open', false))
enddef

# Route to one of the two stable submit verbs.  `as_pending` is derived
# from the key pressed and the review state frozen at buffer open — never
# from the current, possibly changed, review state.
def DispatchSubmit(as_pending: bool)
  var body = GetReplyText()
  if empty(body)
    echo 'No reply text to submit'
    return
  endif

  var is_new = get(b:, 'gh_review_is_new', false)
  if is_new
    if as_pending
      SubmitNewThread(body)
    else
      SubmitStandaloneThread(body)
    endif
  else
    if as_pending
      SubmitPendingReply(body)
    else
      SubmitStandaloneReply(body)
    endif
  endif
enddef

# New comment thread, held in a pending review (GraphQL).
def SubmitNewThread(body: string)
  var path = get(b:, 'gh_review_path', '')
  var line_num = get(b:, 'gh_review_line', 0)
  var start_line = get(b:, 'gh_review_start_line', v:null)
  var side = get(b:, 'gh_review_side', 'RIGHT')

  var vars: dict<any> = {
    pullRequestId: state.GetPRId(),
    body: body,
    path: path,
    line: line_num,
    side: side,
  }
  if start_line != v:null
    vars.startLine = start_line
    vars.startSide = side
  endif

  review.Resolve((review_id) => {
    # If there is no pending review, omit the review ID and GitHub
    # implicitly starts one to hold the new thread.
    if !empty(review_id)
      vars.pullRequestReviewId = review_id
    endif

    echo 'Submitting comment...'
    api.GraphQL(graphql.MUTATION_ADD_REVIEW_THREAD, vars, (result) => {
      var new_thread = get(get(get(result, 'data', {}), 'addPullRequestReviewThread', {}), 'thread', {})
      if !empty(new_thread)
        state.SetThread(new_thread.id, new_thread)
        state.SetLastKnownReviewActive(true)
        diff.RefreshSigns()
        echo 'Comment submitted (pending review)'
        CloseThreadBuffer()
      else
        echoerr '[gh-review] Failed to create thread'
      endif
    })
  })
enddef

# Reply to an existing thread, held in a pending review (GraphQL).
def SubmitPendingReply(body: string)
  var first_comment_id = get(b:, 'gh_review_first_comment_id', '')
  if empty(first_comment_id)
    echoerr '[gh-review] Cannot reply: no comment ID found'
    return
  endif

  review.Resolve((review_id) => {
    if !empty(review_id)
      AddPendingReply(review_id, first_comment_id, body)
      return
    endif
    # No pending review anywhere: start one and attach the reply to it.
    echo 'Starting pending review...'
    var start_vars: dict<any> = {pullRequestId: state.GetPRId()}
    api.GraphQL(graphql.MUTATION_START_REVIEW, start_vars, (result) => {
      var started = get(get(get(result, 'data', {}), 'addPullRequestReview', {}), 'pullRequestReview', {})
      if empty(started)
        echoerr '[gh-review] Failed to start pending review'
        return
      endif
      state.SetLastKnownReviewActive(true)
      AddPendingReply(started.id, first_comment_id, body)
    })
  })
enddef

def AddPendingReply(review_id: string, in_reply_to: string, body: string)
  echo 'Submitting reply...'
  # Note: a script-level def rather than a `var F = () => {...}` lambda —
  # inside such a lambda a line holding only `}` ends the lambda body, so
  # multi-line dict literals there fail to compile.
  var reply_vars: dict<any> = {
    pullRequestReviewId: review_id,
    threadId: in_reply_to,
    body: body,
  }
  api.GraphQL(graphql.MUTATION_ADD_REVIEW_COMMENT, reply_vars, (result) => {
    var comment = get(get(get(result, 'data', {}), 'addPullRequestReviewComment', {}), 'comment', {})
    if !empty(comment)
      state.SetLastKnownReviewActive(true)
      echo 'Reply submitted (pending review)'
      # Refresh the thread to show the new comment
      orchestrator.RefreshThreads()
      CloseThreadBuffer()
    else
      echoerr '[gh-review] Failed to submit reply'
    endif
  })
enddef

# Reply to an existing thread, posted standalone immediately (REST).
def SubmitStandaloneReply(body: string)
  var database_id = get(b:, 'gh_review_first_comment_database_id', 0)
  if database_id == 0
    echoerr '[gh-review] Cannot reply: no numeric comment ID found'
    return
  endif

  var owner = state.GetOwner()
  var name = state.GetName()
  var pr_number = state.GetPRNumber()

  echo 'Submitting reply...'
  api.RunAsync(
    ['api', '-X', 'POST',
     printf('/repos/%s/%s/pulls/%d/comments/%d/replies', owner, name, pr_number, database_id),
     '-f', 'body=' .. body],
    (stdout, stderr) => {
      if !empty(stderr)
        ReportStandaloneError(stdout, stderr)
        return
      endif
      echo 'Reply submitted'
      orchestrator.RefreshThreads()
      CloseThreadBuffer()
    })
enddef

# Report a failed standalone (REST) post.  The thread buffer stays open so
# the text is not lost.
#
# The common failure is a pending review that appeared after this buffer
# was opened (web UI, another session, :GHReviewStart): GitHub then rejects
# standalone comments.  Point the user at Ctrl-A, which resolves the review
# at submit time and so adds the comment to the existing review.
def ReportStandaloneError(stdout: string, stderr: string)
  var detail = trim(stderr)
  try
    var errors = get(json_decode(stdout), 'errors', [])
    var messages = mapnew(errors, (_, e) => get(e, 'message', ''))
    filter(messages, (_, m) => !empty(m))
    if !empty(messages)
      detail = join(messages, '; ')
    endif
  catch
    # Not JSON: fall back to gh's stderr line.
  endtry

  echohl ErrorMsg
  if detail =~# 'one pending review'
    state.SetLastKnownReviewActive(true)
    echomsg '[gh-review] Not posted: you have a pending review, and GitHub only allows'
      .. ' adding comments to it. Press Ctrl-A ("start pending review") to add this'
      .. ' comment to your existing review instead.'
  else
    echomsg '[gh-review] Not posted: ' .. detail
  endif
  echohl None
enddef

# New comment thread, posted standalone immediately (REST).
def SubmitStandaloneThread(body: string)
  var path = get(b:, 'gh_review_path', '')
  var line_num = get(b:, 'gh_review_line', 0)
  var start_line = get(b:, 'gh_review_start_line', v:null)
  var side = get(b:, 'gh_review_side', 'RIGHT')
  var owner = state.GetOwner()
  var name = state.GetName()
  var pr_number = state.GetPRNumber()

  echo 'Submitting comment...'
  # Re-fetch the head SHA right before posting: the endpoint requires a
  # commit_id and the cached one may be stale, which would bind the
  # comment to an outdated commit.
  api.RunAsync(
    ['api', printf('/repos/%s/%s/pulls/%d', owner, name, pr_number)],
    (stdout, stderr) => {
      if !empty(stderr)
        echoerr '[gh-review] ' .. trim(stderr)
        return
      endif
      var head_sha = ''
      try
        head_sha = get(get(json_decode(stdout), 'head', {}), 'sha', '')
      catch
        echoerr '[gh-review] Failed to fetch PR head commit'
        return
      endtry
      if empty(head_sha)
        echoerr '[gh-review] Could not determine PR head commit'
        return
      endif

      var cmd = ['api', '-X', 'POST',
        printf('/repos/%s/%s/pulls/%d/comments', owner, name, pr_number),
        '-f', 'body=' .. body,
        '-f', 'path=' .. path,
        '-F', 'line=' .. line_num,
        '-f', 'side=' .. side,
        '-f', 'commit_id=' .. head_sha,
      ]
      if start_line != v:null
        cmd += ['-F', 'start_line=' .. start_line, '-f', 'start_side=' .. side]
      endif
      api.RunAsync(cmd, (post_stdout, post_stderr) => {
        if !empty(post_stderr)
          ReportStandaloneError(post_stdout, post_stderr)
          return
        endif
        echo 'Comment submitted'
        orchestrator.RefreshThreads()
        CloseThreadBuffer()
      })
    })
enddef

def ToggleResolve()
  var thread_id = get(b:, 'gh_review_thread_id', '')
  if empty(thread_id)
    echo 'Cannot resolve: thread has not been created yet'
    return
  endif

  var is_resolved = get(b:, 'gh_review_is_resolved', false)
  var mutation = is_resolved ? graphql.MUTATION_UNRESOLVE_THREAD : graphql.MUTATION_RESOLVE_THREAD
  var action = is_resolved ? 'Unresolving' : 'Resolving'

  echo action .. ' thread...'
  var resolve_vars: dict<any> = {threadId: thread_id}
  api.GraphQL(mutation, resolve_vars, (result) => {
    var key = is_resolved ? 'unresolveReviewThread' : 'resolveReviewThread'
    var updated = get(get(get(result, 'data', {}), key, {}), 'thread', {})
    if !empty(updated)
      var t = state.GetThread(thread_id)
      t.isResolved = updated.isResolved
      state.SetThread(thread_id, t)
      diff.RefreshSigns()
      echo (is_resolved ? 'Thread unresolved' : 'Thread resolved')
      CloseThreadBuffer()
    else
      echoerr '[gh-review] Failed to ' .. (is_resolved ? 'unresolve' : 'resolve') .. ' thread'
    endif
  })
enddef

def ShowThreadHelp()
  var pending_at_open = get(b:, 'gh_review_pending_at_open', false)
  var [default_label, alt_label] = ModeLabels(pending_at_open)
  var help = [
    ' Thread keymaps',
    ' ' .. repeat("─", 40),
    printf('  Ctrl-S    %s (also :w)', default_label),
  ]
  if !empty(alt_label)
    add(help, printf('  Ctrl-A    %s', alt_label))
  endif
  help += [
    '  Ctrl-R    Toggle resolved',
    '  q         Close thread',
    '  Ctrl-Q    Close thread (insert mode)',
    '  Ctrl-X Ctrl-O  @-mention completion',
    '  g?        This help',
  ]
  popup_atcursor(help, {
    border: [],
    padding: [0, 1, 0, 1],
    close: 'click',
    filter: (winid, key) => {
      if key == 'q' || key == "\<Esc>"
        popup_close(winid)
        return true
      endif
      return false
    },
  })
enddef

# Omnifunc for @-mention completion in thread reply buffer.
# This is a global function because omnifunc requires it.
def g:GHReviewThreadOmnifunc(findstart: number, base: string): any
  if findstart
    var line_text = getline('.')
    var col = col('.') - 1
    while col > 0 && line_text[col - 1] != '@'
      col -= 1
    endwhile
    if col > 0 && line_text[col - 1] == '@'
      return col
    endif
    return -2
  endif
  var participants = state.GetParticipants()
  var matches: list<string> = []
  for p in participants
    if p =~? '^' .. base
      add(matches, p)
    endif
  endfor
  return matches
enddef

export def CloseThreadBuffer()
  var bufnr = state.GetThreadBufnr()
  if bufnr != -1 && bufexists(bufnr)
    var winid = bufwinid(bufnr)
    if winid != -1
      win_gotoid(winid)
      setlocal nomodified
      close
    endif
    if bufexists(bufnr)
      execute 'silent! bwipeout!' bufnr
    endif
  endif
  state.SetThreadBufnr(-1)
  state.SetThreadWinid(-1)

  # Let diff windows expand into the freed space and redraw.
  # In diff/scrollbind mode, the viewport doesn\'t update to fill
  # the new window height. Nudge each window\'s scroll position to
  # force Vim to recompute the visible area.
  wincmd =
  var left_winid = bufwinid(state.GetLeftBufnr())
  if left_winid != -1
    win_gotoid(left_winid)
    execute "normal! \<C-e>\<C-y>"
  endif
  var right_winid = bufwinid(state.GetRightBufnr())
  if right_winid != -1
    win_gotoid(right_winid)
    execute "normal! \<C-e>\<C-y>"
  endif
enddef
