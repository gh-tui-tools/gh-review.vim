vim9script

# Tests for pending-review resolution and submit routing.  The gh CLI is
# replaced by a mock that simulates the server-side pending-review state,
# so these tests cover which API calls each action makes and how it
# adapts when the server state differs from the local hint.

var test_dir = expand('<sfile>:p:h')
execute 'source ' .. test_dir .. '/helpers.vim'
execute 'source ' .. test_dir .. '/fixtures.vim'

# Shadow gh_review/job.vim (the process boundary) with test/mock's double.
# Must precede every autoload import below, which resolve the module path
# via 'runtimepath' in order.
&rtp = test_dir .. '/mock,' .. &rtp

import autoload 'gh_review/job.vim' as fake_job
import autoload 'gh_review/state.vim'
import autoload 'gh_review/graphql.vim'
import autoload 'gh_review/thread.vim'
import autoload 'gh_review.vim' as orchestrator

# --- Mock GitHub ---

# The viewer's pending review ID on the simulated server ('' = none).
var server_pending = ''
# Recorded calls: {op: string, vars: dict<any>}
var calls: list<dict<any>> = []
# Set by Respond() to simulate a failing REST call (gh exits 1, prints
# "gh: ... (HTTP nnn)" to stderr and the response body to stdout).
var resp_stderr = ''

const OPS = {
  [graphql.QUERY_PENDING_REVIEW]: 'lookup',
  [graphql.QUERY_REVIEW_THREADS]: 'refresh',
  [graphql.MUTATION_START_REVIEW]: 'start',
  [graphql.MUTATION_SUBMIT_REVIEW]: 'submit',
  [graphql.MUTATION_CREATE_AND_SUBMIT_REVIEW]: 'create_and_submit',
  [graphql.MUTATION_ADD_REVIEW_THREAD]: 'add_thread',
  [graphql.MUTATION_ADD_REVIEW_COMMENT]: 'add_reply',
  [graphql.MUTATION_DELETE_REVIEW]: 'delete',
}

def ParseCmd(cmd: list<string>): dict<any>
  # cmd: ['gh', 'api', ...]
  var args = cmd[2 :]
  var vars: dict<any> = {}
  var method = 'GET'
  var path = ''
  var i = 0
  while i < len(args)
    var a = args[i]
    if a ==# '-f' || a ==# '-F'
      var [key, val] = matchlist(args[i + 1], '\v^([^=]+)\=(.*)$')[1 : 2]
      vars[key] = a ==# '-F' && val =~# '^\d\+$' ? str2nr(val) : val
      i += 2
    elseif a ==# '-X'
      method = args[i + 1]
      i += 2
    else
      path = a
      i += 1
    endif
  endwhile
  if path ==# 'graphql'
    var query = remove(vars, 'query')
    return {op: get(OPS, query, 'unknown_graphql'), vars: vars}
  endif
  return {op: method .. ' ' .. path, vars: vars}
enddef

def PendingNodes(): list<any>
  return empty(server_pending) ? [] : [{id: server_pending, state: 'PENDING', viewerDidAuthor: true}]
enddef

def Respond(call: dict<any>): dict<any>
  var op = call.op
  if op ==# 'lookup'
    return {data: {repository: {pullRequest: {reviews: {nodes: PendingNodes()}}}}}
  elseif op ==# 'refresh'
    return {data: {repository: {pullRequest: {reviewThreads: {nodes: []}, reviews: {nodes: PendingNodes()}}}}}
  elseif op ==# 'start'
    if !empty(server_pending)
      return {errors: [{message: 'User can only have one pending review per pull request'}]}
    endif
    server_pending = 'srv_started'
    return {data: {addPullRequestReview: {pullRequestReview: {id: server_pending, state: 'PENDING'}}}}
  elseif op ==# 'submit'
    if call.vars.reviewId !=# server_pending
      return {errors: [{message: 'Could not resolve to a node with the global id'}]}
    endif
    server_pending = ''
    return {data: {submitPullRequestReview: {pullRequestReview: {id: call.vars.reviewId, state: 'COMMENTED'}}}}
  elseif op ==# 'create_and_submit'
    if !empty(server_pending)
      return {errors: [{message: 'User can only have one pending review per pull request'}]}
    endif
    return {data: {addPullRequestReview: {pullRequestReview: {id: 'srv_oneshot', state: 'COMMENTED'}}}}
  elseif op ==# 'add_thread'
    var review_id = get(call.vars, 'pullRequestReviewId', '')
    if !empty(review_id) && review_id !=# server_pending
      return {errors: [{message: 'Could not resolve to a node with the global id'}]}
    endif
    if empty(server_pending)
      server_pending = 'srv_implicit'
    endif
    return {data: {addPullRequestReviewThread: {thread: {
      id: 'new_thread', path: call.vars.path, line: call.vars.line, diffSide: call.vars.side,
      isResolved: false,
      comments: {nodes: [{id: 'new_comment', databaseId: 2001, body: call.vars.body,
        author: {login: 'me'}, createdAt: '2025-01-20T00:00:00Z',
        pullRequestReview: {id: server_pending, state: 'PENDING'}}]}}}}}
  elseif op ==# 'add_reply'
    if call.vars.pullRequestReviewId !=# server_pending
      return {errors: [{message: 'Could not resolve to a node with the global id'}]}
    endif
    return {data: {addPullRequestReviewComment: {comment: {id: 'reply_comment', databaseId: 2002}}}}
  elseif op ==# 'delete'
    server_pending = ''
    return {data: {deletePullRequestReview: {pullRequestReview: {id: call.vars.pullRequestReviewId, state: 'PENDING'}}}}
  elseif op =~# '^POST '
    if !empty(server_pending)
      # Real GitHub response (verified against the API): standalone review
      # comments and replies are rejected while a pending review exists.
      resp_stderr = 'gh: Validation Failed (HTTP 422)'
      return {message: 'Validation Failed', status: '422', errors: [{
        resource: 'PullRequestReview', code: 'custom', field: 'user_id',
        message: 'user_id can only have one pending review per pull request'}]}
    endif
    return {id: 3001}
  endif
  return {errors: [{message: 'mock: unhandled op ' .. op}]}
enddef

def MockRunner(cmd: list<string>): list<any>
  var call = ParseCmd(cmd)
  add(calls, call)
  resp_stderr = ''
  var body = json_encode(Respond(call))
  return [body, resp_stderr, empty(resp_stderr) ? 0 : 1]
enddef

def Ops(): list<string>
  return mapnew(calls, (_, c) => c.op)
enddef

def FindCall(op: string): dict<any>
  for c in calls
    if c.op ==# op
      return c
    endif
  endfor
  return {}
enddef

# Load the mock PR.  `hint` sets the local (display-only) pending-review
# state; `server` sets the pending review ID on the simulated server.
def Setup(hint: bool, server: string)
  state.Reset()
  var data = g:MockPRData()
  if !hint
    data.data.repository.pullRequest.reviews.nodes = []
  endif
  state.SetPR(data)
  state.SetRepoInfo('testowner', 'testrepo')
  state.SetThreads(g:MockThreadNodes())
  server_pending = server
  calls = []
  messages clear
  fake_job.SetResponder(MockRunner)
enddef

def Teardown()
  fake_job.ClearResponder()
  thread.CloseThreadBuffer()
  state.Reset()
enddef

# Type `text` into the reply area of the open thread buffer.
def TypeReply(text: string)
  var bufnr = state.GetThreadBufnr()
  setbufvar(bufnr, '&modifiable', true)
  setbufline(bufnr, getbufvar(bufnr, 'gh_review_reply_start'), text)
enddef

def OpenNewComment()
  # Pass the body directly: startinsert is unreliable in headless Vim.
  thread.OpenNew('src/new_file.ts', 5, 5, 'RIGHT', 'a new comment')
enddef

def OpenReply()
  thread.Open('thread_1')
  TypeReply('a reply')
enddef

def Press(key: string)
  execute 'normal ' .. key
enddef

# Run Fn and return the exception it throws ('' if none).
def Catch(Fn: func()): string
  try
    Fn()
  catch
    return v:exception
  endtry
  return ''
enddef

# --- Sanity ---

g:RunTest('gh_review/job.vim resolves to the test double', () => {
  # Guards against silently running the real gh if the rtp setup breaks.
  assert_true(fake_job.IS_MOCK)
  assert_match('/test/mock/autoload/gh_review/job\.vim$',
    getscriptinfo({name: 'gh_review/job\.vim$'})[0].name)
})

# --- New comment threads ---

g:RunTest('No review: Ctrl-S posts a new comment standalone via REST', () => {
  Setup(false, '')
  OpenNewComment()
  Press("\<C-s>")

  assert_equal(['POST /repos/testowner/testrepo/pulls/42/comments', 'refresh'], Ops())
  var post = FindCall('POST /repos/testowner/testrepo/pulls/42/comments')
  assert_equal('a new comment', post.vars.body)
  assert_equal('src/new_file.ts', post.vars.path)
  assert_equal(5, post.vars.line)
  assert_equal('RIGHT', post.vars.side)
  assert_equal('', server_pending, 'must not create a pending review')
  Teardown()
})

g:RunTest(':w performs the same default action as Ctrl-S', () => {
  Setup(false, '')
  OpenNewComment()
  silent write

  assert_equal('POST /repos/testowner/testrepo/pulls/42/comments', get(Ops(), 0, ''))
  Teardown()
})

g:RunTest('No review: Ctrl-G starts a pending review with the comment', () => {
  Setup(false, '')
  OpenNewComment()
  Press("\<C-g>")

  assert_equal(['lookup', 'add_thread'], Ops())
  assert_false(has_key(FindCall('add_thread').vars, 'pullRequestReviewId'),
    'no review ID: GitHub starts one implicitly')
  assert_equal('srv_implicit', server_pending)
  assert_true(state.LastKnownReviewActive(), 'hint updated after implicit start')
  Teardown()
})

g:RunTest('Unseen server review: Ctrl-G attaches the comment to it', () => {
  # The original bug: a pending review exists that the plugin never saw.
  Setup(false, 'srv_unseen')
  OpenNewComment()
  Press("\<C-g>")

  assert_equal(['lookup', 'add_thread'], Ops())
  assert_equal('srv_unseen', FindCall('add_thread').vars.pullRequestReviewId)
  Teardown()
})

g:RunTest('Review active: Ctrl-S adds the comment to the current review', () => {
  Setup(true, 'srv_rev')
  OpenNewComment()
  Press("\<C-s>")

  assert_equal(['lookup', 'add_thread'], Ops())
  assert_equal('srv_rev', FindCall('add_thread').vars.pullRequestReviewId)
  Teardown()
})

g:RunTest('Stale hint: Ctrl-S never sends a dead review ID', () => {
  # Hint says a review is active, but it was submitted elsewhere.
  Setup(true, '')
  OpenNewComment()
  Press("\<C-s>")

  assert_equal(['lookup', 'add_thread'], Ops())
  assert_false(has_key(FindCall('add_thread').vars, 'pullRequestReviewId'))
  assert_equal('srv_implicit', server_pending)
  Teardown()
})

g:RunTest('Review mode: Ctrl-G is not mapped and not advertised', () => {
  # GitHub rejects standalone comments while a pending review exists, so
  # review mode offers no alternative action.
  Setup(true, 'srv_rev')
  OpenNewComment()
  assert_equal('', maparg('<C-g>', 'n'))
  assert_equal('', maparg('<C-g>', 'i'))
  assert_notequal('', maparg('<C-s>', 'n'))
  var text = join(getbufline(state.GetThreadBufnr(), 1, '$'), "\n")
  assert_match('── Ctrl-S: add to pending review · Ctrl-Q: cancel ──', text)
  assert_notmatch('Ctrl-G', text)
  Teardown()
})

g:RunTest('No-review mode maps Ctrl-G', () => {
  Setup(false, '')
  OpenNewComment()
  assert_notequal('', maparg('<C-g>', 'n'))
  assert_notequal('', maparg('<C-g>', 'i'))
  Teardown()
})

g:RunTest('Review started meanwhile: Ctrl-S fails clearly, Ctrl-G adds to it', () => {
  Setup(false, '')
  OpenNewComment()
  var bufnr = state.GetThreadBufnr()
  # A review gets started meanwhile (web UI, another session, ...).
  server_pending = 'srv_meanwhile'

  # Separator promised "post comment now", so that is what is attempted.
  Press("\<C-s>")
  assert_equal(['POST /repos/testowner/testrepo/pulls/42/comments'], Ops())
  var msgs = execute('messages')
  assert_match('you have a pending review', msgs)
  assert_match('Press Ctrl-G', msgs)
  assert_notmatch('HTTP 422', msgs, 'raw gh error replaced by an explanation')
  assert_true(bufexists(bufnr), 'buffer kept open so the text is not lost')
  assert_true(state.LastKnownReviewActive(), 'hint learns about the review')

  # Ctrl-G ("start pending review") resolves and appends to the existing one.
  calls = []
  Press("\<C-g>")
  assert_equal(['lookup', 'add_thread'], Ops())
  assert_equal('srv_meanwhile', FindCall('add_thread').vars.pullRequestReviewId)
  assert_equal('a new comment', FindCall('add_thread').vars.body)
  assert_false(bufexists(bufnr), 'buffer closed after success')
  Teardown()
})

g:RunTest('Review started meanwhile: standalone reply fails clearly, Ctrl-G adds to it', () => {
  Setup(false, '')
  OpenReply()
  server_pending = 'srv_meanwhile'

  Press("\<C-s>")
  assert_equal(['POST /repos/testowner/testrepo/pulls/42/comments/1001/replies'], Ops())
  assert_match('Press Ctrl-G', execute('messages'))
  assert_notequal(-1, state.GetThreadBufnr())

  calls = []
  Press("\<C-g>")
  assert_equal(['lookup', 'add_reply', 'refresh'], Ops(), 'no new review started')
  assert_equal('srv_meanwhile', FindCall('add_reply').vars.pullRequestReviewId)
  Teardown()
})

g:RunTest('Other REST errors show the GitHub message', () => {
  Setup(false, '')
  OpenReply()
  # Simulate a different failure by breaking the target comment ID.
  setbufvar(state.GetThreadBufnr(), 'gh_review_first_comment_database_id', 999)
  fake_job.SetResponder((cmd) => {
    add(calls, ParseCmd(cmd))
    return [json_encode({message: 'Not Found', errors: []}), 'gh: Not Found (HTTP 404)', 1]
  })
  Press("\<C-s>")
  assert_match('Not posted: gh: Not Found (HTTP 404)', execute('messages'))
  assert_notequal(-1, state.GetThreadBufnr())
  Teardown()
})

# --- Replies to existing threads ---

g:RunTest('No review: Ctrl-S posts a reply standalone via REST', () => {
  Setup(false, '')
  OpenReply()
  Press("\<C-s>")

  assert_equal(['POST /repos/testowner/testrepo/pulls/42/comments/1001/replies', 'refresh'], Ops())
  assert_equal('a reply', calls[0].vars.body)
  Teardown()
})

g:RunTest('No review: Ctrl-G starts a review and adds the reply to it', () => {
  Setup(false, '')
  OpenReply()
  Press("\<C-g>")

  assert_equal(['lookup', 'start', 'add_reply', 'refresh'], Ops())
  var reply = FindCall('add_reply')
  assert_equal('srv_started', reply.vars.pullRequestReviewId)
  assert_equal('comment_1', reply.vars.threadId)
  assert_true(state.LastKnownReviewActive())
  Teardown()
})

g:RunTest('Unseen server review: Ctrl-G adds the reply to it without starting one', () => {
  Setup(false, 'srv_unseen')
  OpenReply()
  Press("\<C-g>")

  assert_equal(['lookup', 'add_reply', 'refresh'], Ops())
  assert_equal('srv_unseen', FindCall('add_reply').vars.pullRequestReviewId)
  Teardown()
})

g:RunTest('Stale hint: pending reply starts a fresh review', () => {
  Setup(true, '')
  OpenReply()
  Press("\<C-s>")

  assert_equal(['lookup', 'start', 'add_reply', 'refresh'], Ops())
  assert_equal('srv_started', FindCall('add_reply').vars.pullRequestReviewId)
  Teardown()
})

# --- Review lifecycle ---

g:RunTest('SubmitReviewAs submits an unseen server review', () => {
  Setup(false, 'srv_unseen')
  orchestrator.SubmitReviewAs('APPROVE', '')

  assert_equal(['lookup', 'submit', 'refresh'], Ops())
  var submit = FindCall('submit')
  assert_equal('srv_unseen', submit.vars.reviewId)
  assert_equal('APPROVE', submit.vars.event)
  assert_false(has_key(submit.vars, 'body'))
  assert_false(state.LastKnownReviewActive())
  Teardown()
})

g:RunTest('SubmitReviewAs creates and submits when no review exists', () => {
  Setup(true, '')
  orchestrator.SubmitReviewAs('COMMENT', 'LGTM')

  assert_equal(['lookup', 'create_and_submit', 'refresh'], Ops())
  var cs = FindCall('create_and_submit')
  assert_equal('PR_abc123', cs.vars.pullRequestId)
  assert_equal('LGTM', cs.vars.body)
  assert_false(state.LastKnownReviewActive())
  Teardown()
})

g:RunTest('StartReview adopts an existing server review', () => {
  Setup(false, 'srv_unseen')
  orchestrator.StartReview()

  assert_equal(['lookup'], Ops())
  assert_true(state.LastKnownReviewActive())
  Teardown()
})

g:RunTest('StartReview starts a review when none exists', () => {
  Setup(true, '')
  orchestrator.StartReview()

  assert_equal(['lookup', 'start'], Ops())
  assert_equal('srv_started', server_pending)
  assert_true(state.LastKnownReviewActive())
  Teardown()
})

g:RunTest('DiscardReview reports when there is nothing to discard', () => {
  Setup(true, '')
  var err = Catch(() => {
    orchestrator.DiscardReview()
  })

  assert_match('No pending review to discard', err)
  assert_equal(['lookup'], Ops())
  assert_false(state.LastKnownReviewActive(), 'stale hint cleared')
  Teardown()
})

g:RunTest('RefreshThreads updates the review hint from the server', () => {
  Setup(false, 'srv_unseen')
  orchestrator.RefreshThreads()
  assert_true(state.LastKnownReviewActive())

  server_pending = ''
  orchestrator.RefreshThreads()
  assert_false(state.LastKnownReviewActive())
  Teardown()
})

# --- Write results and exit ---

g:WriteResults('/tmp/gh_review_test_review.txt')
