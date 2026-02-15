vim9script

# Tests for autoload/gh_review/state.vim

var test_dir = expand('<sfile>:p:h')
execute 'source ' .. test_dir .. '/helpers.vim'
execute 'source ' .. test_dir .. '/fixtures.vim'

import autoload 'gh_review/state.vim'
import autoload 'gh_review.vim' as orchestrator

# --- Tests ---

g:RunTest('SetPR populates all getters', () => {
  state.Reset()
  state.SetPR(g:MockPRData())

  assert_equal('PR_abc123', state.GetPRId())
  assert_equal(42, state.GetPRNumber())
  assert_equal('Add feature X', state.GetPRTitle())
  assert_equal('OPEN', state.GetPRState())
  assert_equal('main', state.GetBaseRef())
  assert_equal('aaa111', state.GetBaseOid())
  assert_equal('feature-x', state.GetHeadRef())
  assert_equal('bbb222', state.GetHeadOid())
  assert_equal('testowner', state.GetHeadRepoOwner())
  assert_equal('testrepo', state.GetHeadRepoName())
})

g:RunTest('SetPR loads changed files', () => {
  state.Reset()
  state.SetPR(g:MockPRData())

  var files = state.GetChangedFiles()
  assert_equal(3, len(files))
  assert_equal('src/new_file.ts', files[0].path)
  assert_equal('ADDED', files[0].changeType)
  assert_equal(50, files[0].additions)
  assert_equal('src/existing.ts', files[1].path)
  assert_equal('MODIFIED', files[1].changeType)
  assert_equal('src/old_file.ts', files[2].path)
  assert_equal('DELETED', files[2].changeType)
})

g:RunTest('SetPR detects pending review', () => {
  state.Reset()
  state.SetPR(g:MockPRData())

  assert_equal(true, state.IsReviewActive())
  assert_equal('pending_rev_1', state.GetPendingReviewId())
})

g:RunTest('IsReviewActive false when no pending review', () => {
  state.Reset()
  # Build data with no pending reviews
  var data = g:MockPRData()
  data.data.repository.pullRequest.reviews.nodes = []
  state.SetPR(data)

  assert_equal(false, state.IsReviewActive())
  assert_equal('', state.GetPendingReviewId())
})

g:RunTest('SetThreads and GetThreads', () => {
  state.Reset()
  state.SetThreads(g:MockThreadNodes())

  var threads = state.GetThreads()
  assert_equal(4, len(threads))
  assert_true(has_key(threads, 'thread_1'))
  assert_true(has_key(threads, 'thread_2'))
  assert_true(has_key(threads, 'thread_3'))
  assert_true(has_key(threads, 'thread_4'))
})

g:RunTest('GetThread returns correct data', () => {
  state.Reset()
  state.SetThreads(g:MockThreadNodes())

  var t = state.GetThread('thread_1')
  assert_equal('thread_1', t.id)
  assert_equal(false, t.isResolved)
  assert_equal(10, t.line)
  assert_equal('RIGHT', t.diffSide)
  assert_equal('src/new_file.ts', t.path)
})

g:RunTest('GetThread returns empty for missing id', () => {
  state.Reset()
  state.SetThreads(g:MockThreadNodes())

  var t = state.GetThread('nonexistent')
  assert_equal({}, t)
})

g:RunTest('GetThreadsForFile filters correctly', () => {
  state.Reset()
  state.SetThreads(g:MockThreadNodes())

  var new_file_threads = state.GetThreadsForFile('src/new_file.ts')
  assert_equal(2, len(new_file_threads))

  var existing_threads = state.GetThreadsForFile('src/existing.ts')
  assert_equal(2, len(existing_threads))

  var no_threads = state.GetThreadsForFile('src/old_file.ts')
  assert_equal(0, len(no_threads))

  var missing = state.GetThreadsForFile('nonexistent.ts')
  assert_equal(0, len(missing))
})

g:RunTest('SetThread adds/updates individual thread', () => {
  state.Reset()
  state.SetThreads(g:MockThreadNodes())

  # Add a new thread
  var new_thread = {id: 'thread_new', isResolved: false, line: 99, diffSide: 'RIGHT', path: 'src/new_file.ts', comments: {nodes: []}}
  state.SetThread('thread_new', new_thread)

  var t = state.GetThread('thread_new')
  assert_equal('thread_new', t.id)
  assert_equal(99, t.line)

  # Update existing thread
  var updated = state.GetThread('thread_1')
  updated.isResolved = true
  state.SetThread('thread_1', updated)
  assert_equal(true, state.GetThread('thread_1').isResolved)
})

g:RunTest('Reset clears all state', () => {
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  state.SetMergeBaseOid('merge123')
  state.SetDiffPath('some/path.ts')
  state.SetFilesBufnr(100)
  state.SetLeftBufnr(300)
  state.SetRightBufnr(400)
  state.SetThreadBufnr(500)
  state.SetThreadWinid(600)

  state.Reset()

  assert_equal('', state.GetPRId())
  assert_equal(0, state.GetPRNumber())
  assert_equal('', state.GetPRTitle())
  assert_equal('', state.GetPRState())
  assert_equal('', state.GetBaseRef())
  assert_equal('', state.GetBaseOid())
  assert_equal('', state.GetHeadRef())
  assert_equal('', state.GetHeadOid())
  assert_equal('', state.GetHeadRepoOwner())
  assert_equal('', state.GetHeadRepoName())
  assert_equal('', state.GetMergeBaseOid())
  assert_equal('', state.GetOwner())
  assert_equal('', state.GetName())
  assert_equal([], state.GetChangedFiles())
  assert_equal({}, state.GetThreads())
  assert_equal('', state.GetPendingReviewId())
  assert_equal(false, state.IsReviewActive())
  assert_equal(-1, state.GetFilesBufnr())
  assert_equal(-1, state.GetLeftBufnr())
  assert_equal(-1, state.GetRightBufnr())
  assert_equal(-1, state.GetThreadBufnr())
  assert_equal(-1, state.GetThreadWinid())
  assert_equal('', state.GetDiffPath())
})

g:RunTest('Buffer/window setters and getters', () => {
  state.Reset()

  state.SetFilesBufnr(10)
  assert_equal(10, state.GetFilesBufnr())

  state.SetLeftBufnr(30)
  assert_equal(30, state.GetLeftBufnr())

  state.SetRightBufnr(40)
  assert_equal(40, state.GetRightBufnr())

  state.SetThreadBufnr(50)
  assert_equal(50, state.GetThreadBufnr())

  state.SetThreadWinid(60)
  assert_equal(60, state.GetThreadWinid())

  state.SetDiffPath('foo/bar.ts')
  assert_equal('foo/bar.ts', state.GetDiffPath())

  state.SetMergeBaseOid('ccc333')
  assert_equal('ccc333', state.GetMergeBaseOid())

  state.SetPendingReviewId('rev_xyz')
  assert_equal('rev_xyz', state.GetPendingReviewId())
  assert_equal(true, state.IsReviewActive())
})

g:RunTest('SetPR populates head repo for fork PR', () => {
  state.Reset()
  state.SetPR(g:MockForkPRData())

  assert_equal('forkuser', state.GetHeadRepoOwner())
  assert_equal('testrepo', state.GetHeadRepoName())
  assert_equal('fork-feature', state.GetHeadRef())
})


g:RunTest('SetPR handles null headRepository (deleted fork)', () => {
  state.Reset()
  state.SetPR(g:MockDeletedForkPRData())

  # Core PR fields still populated
  assert_equal('PR_abc123', state.GetPRId())
  assert_equal(42, state.GetPRNumber())
  assert_equal('Add feature X', state.GetPRTitle())
  assert_equal('main', state.GetBaseRef())
  assert_equal('feature-x', state.GetHeadRef())

  # Head repo fields remain empty since headRepository is null
  assert_equal('', state.GetHeadRepoOwner())
  assert_equal('', state.GetHeadRepoName())
})

g:RunTest('SetThreads with empty list produces empty threads', () => {
  state.Reset()
  state.SetThreads([])

  assert_equal({}, state.GetThreads())
  assert_equal([], state.GetThreadsForFile('any/file.ts'))
  assert_equal({}, state.GetThread('nonexistent'))
})


g:RunTest('GetParticipants extracts unique sorted logins', () => {
  state.Reset()
  state.SetThreads(g:MockThreadNodes())

  var participants = state.GetParticipants()
  assert_equal(2, len(participants))
  assert_equal('alice', participants[0])
  assert_equal('bob', participants[1])
})

g:RunTest('GetParticipants returns empty for no threads', () => {
  state.Reset()
  state.SetThreads([])

  var participants = state.GetParticipants()
  assert_equal(0, len(participants))
})

g:RunTest('Statusline returns empty when no PR loaded', () => {
  state.Reset()
  assert_equal('', orchestrator.Statusline())
})

g:RunTest('Statusline shows PR number when loaded', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  var result = orchestrator.Statusline()
  assert_match('PR #42', result)
  assert_match('4 threads', result)
})

g:RunTest('Statusline shows reviewing when review active', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads([])
  var result = orchestrator.Statusline()
  assert_match('reviewing', result)
})

g:RunTest('Statusline omits reviewing when no pending review', () => {
  state.Reset()
  var data = g:MockPRData()
  data.data.repository.pullRequest.reviews.nodes = []
  state.SetPR(data)
  state.SetThreads([])
  var result = orchestrator.Statusline()
  assert_match('PR #42', result)
  assert_true(result !~# 'reviewing', 'should not contain reviewing')
})

g:RunTest('Statusline singular thread', () => {
  state.Reset()
  var data = g:MockPRData()
  data.data.repository.pullRequest.reviews.nodes = []
  state.SetPR(data)
  state.SetThreads([
    {id: 't1', isResolved: false, line: 1, diffSide: 'RIGHT', path: 'x.ts', comments: {nodes: []}},
  ])
  var result = orchestrator.Statusline()
  assert_match('1 thread', result)
  assert_true(result !~# 'threads', 'should be singular')
})

# --- Write results and exit ---

g:WriteResults('/tmp/gh_review_test_state.txt')
