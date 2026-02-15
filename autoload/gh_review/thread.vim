vim9script

# Thread/comment buffer for viewing and replying to review threads.

import autoload 'gh_review/state.vim'
import autoload 'gh_review/api.vim'
import autoload 'gh_review/graphql.vim'
import autoload 'gh_review/diff.vim'

const REPLY_SEPARATOR = "── Reply below (Ctrl-S to submit, Ctrl-R to resolve, Ctrl-Q to cancel) ──"

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
    add(lines, '')
  endfor

  # Reply separator
  add(lines, REPLY_SEPARATOR)
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

  # Store the first comment id (needed for REST reply)
  if !empty(comments)
    b:gh_review_first_comment_id = comments[0].id
  endif

  # Make the header area read-only via autocmd
  augroup gh_review_thread
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> SubmitReply()
    autocmd CursorMoved,CursorMovedI <buffer> EnforceReadOnly()
  augroup END

  # Keymaps
  nnoremap <buffer> <silent> <C-s> <ScriptCmd>SubmitReply()<CR>
  inoremap <buffer> <silent> <C-s> <Esc><ScriptCmd>SubmitReply()<CR>
  nnoremap <buffer> <silent> <C-r> <ScriptCmd>ToggleResolve()<CR>
  nnoremap <buffer> <silent> q <ScriptCmd>CloseThreadBuffer()<CR>
  nnoremap <buffer> <silent> <C-q> <ScriptCmd>CloseThreadBuffer()<CR>
  inoremap <buffer> <silent> <C-q> <Esc><ScriptCmd>CloseThreadBuffer()<CR>
  nnoremap <buffer> <silent> g? <ScriptCmd>ShowThreadHelp()<CR>

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

def SubmitReply()
  var body = GetReplyText()
  if empty(body)
    echo 'No reply text to submit'
    return
  endif

  var thread_id = get(b:, 'gh_review_thread_id', '')
  var is_new = get(b:, 'gh_review_is_new', false)

  if is_new
    SubmitNewThread(body)
  elseif state.IsReviewActive()
    SubmitReviewReply(body)
  else
    SubmitStandaloneReply(body)
  endif
enddef

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

  if state.IsReviewActive()
    vars.pullRequestReviewId = state.GetPendingReviewId()
  endif

  echo 'Submitting comment...'
  api.GraphQL(graphql.MUTATION_ADD_REVIEW_THREAD, vars, (result) => {
    var new_thread = get(get(get(result, 'data', {}), 'addPullRequestReviewThread', {}), 'thread', {})
    if !empty(new_thread)
      state.SetThread(new_thread.id, new_thread)
      diff.RefreshSigns()
      echo 'Comment submitted'
      CloseThreadBuffer()
    else
      echoerr '[gh-review] Failed to create thread'
    endif
  })
enddef

def SubmitReviewReply(body: string)
  var first_comment_id = get(b:, 'gh_review_first_comment_id', '')
  if empty(first_comment_id)
    echoerr '[gh-review] Cannot reply: no comment ID found'
    return
  endif

  echo 'Submitting reply...'
  var reply_vars: dict<any> = {
    pullRequestReviewId: state.GetPendingReviewId(),
    threadId: first_comment_id,
    body: body,
  }
  api.GraphQL(graphql.MUTATION_ADD_REVIEW_COMMENT, reply_vars, (result) => {
    var comment = get(get(get(result, 'data', {}), 'addPullRequestReviewComment', {}), 'comment', {})
    if !empty(comment)
      echo 'Reply submitted (pending review)'
      # Refresh the thread to show the new comment
      import autoload 'gh_review.vim' as orchestrator
      orchestrator.RefreshThreads()
      CloseThreadBuffer()
    else
      echoerr '[gh-review] Failed to submit reply'
    endif
  })
enddef

def SubmitStandaloneReply(body: string)
  var first_comment_id = get(b:, 'gh_review_first_comment_id', '')
  if empty(first_comment_id)
    echoerr '[gh-review] Cannot reply: no comment ID found'
    return
  endif

  # Extract the numeric comment ID from the GraphQL node ID
  # Node IDs look like "IC_kwDOBN..." -- we need the REST API numeric ID
  # Use the REST API endpoint that accepts GraphQL node IDs
  var owner = state.GetOwner()
  var name = state.GetName()
  var pr_number = state.GetPRNumber()

  echo 'Submitting reply...'
  api.RunAsync(
    ['api', '-X', 'POST',
     printf('/repos/%s/%s/pulls/%d/comments/%s/replies', owner, name, pr_number, first_comment_id),
     '-f', 'body=' .. body],
    (stdout, stderr) => {
      if !empty(stderr) && stdout !~# '"id"'
        # The REST API might not accept node IDs directly for the path param.
        # Fall back: use the graphql-compatible endpoint
        SubmitReplyViaGraphQL(body, first_comment_id)
        return
      endif
      echo 'Reply submitted'
      import autoload 'gh_review.vim' as orchestrator
      orchestrator.RefreshThreads()
      CloseThreadBuffer()
    })
enddef

def SubmitReplyViaGraphQL(body: string, in_reply_to: string)
  # Use addPullRequestReviewComment without a review ID by creating
  # a single-comment review
  var start_vars: dict<any> = {pullRequestId: state.GetPRId()}
  api.GraphQL(graphql.MUTATION_START_REVIEW, start_vars, (result) => {
    var review = get(get(get(result, 'data', {}), 'addPullRequestReview', {}), 'pullRequestReview', {})
    if empty(review)
      echoerr '[gh-review] Failed to create review for reply'
      return
    endif
    var review_id = review.id

    var inner_vars: dict<any> = {pullRequestReviewId: review_id, threadId: in_reply_to, body: body}
    api.GraphQL(graphql.MUTATION_ADD_REVIEW_COMMENT, inner_vars, (inner_result) => {
      # Submit the review immediately as COMMENT
      var submit_vars: dict<any> = {reviewId: review_id, event: 'COMMENT'}
      api.GraphQL(graphql.MUTATION_SUBMIT_REVIEW, submit_vars, (_) => {
        echo 'Reply submitted'
        import autoload 'gh_review.vim' as orchestrator
        orchestrator.RefreshThreads()
        CloseThreadBuffer()
      })
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
  var help = [
    ' Thread keymaps',
    ' ' .. repeat("─", 40),
    '  Ctrl-S    Submit reply',
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
