vim9script

# Tests for diff navigation helpers and thread opening logic.
# Note: ]t/[t/gt keymaps are buffer-local, installed by the script-local
# SetupDiffBuffer, so we cannot test them directly from here. Instead we
# test the underlying behaviour through signs and exported functions.

var test_dir = expand('<sfile>:p:h')
execute 'source ' .. test_dir .. '/helpers.vim'
execute 'source ' .. test_dir .. '/fixtures.vim'

import autoload 'gh_review/state.vim'
import autoload 'gh_review/diff.vim'
import autoload 'gh_review/thread.vim'

# Helper: create a scratch buffer with N lines of content.
def SetupBuffer(name: string, num_lines: number): number
  var bufnr = bufnr(name, true)
  execute 'buffer' bufnr
  setlocal buftype=nofile
  setlocal noswapfile
  setlocal modifiable
  var lines: list<string> = []
  for i in range(1, num_lines)
    add(lines, 'line ' .. i)
  endfor
  deletebufline(bufnr, 1, '$')
  setbufline(bufnr, 1, lines)
  setlocal nomodifiable
  setlocal signcolumn=yes
  return bufnr
enddef

# --- Tests ---

g:RunTest('Signs placed on both sides for mixed-side threads', () => {
  state.Reset()

  enew
  var left = SetupBuffer('gh-review://LEFT/src/sides.ts', 50)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/sides.ts', 50)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/sides.ts')

  state.SetThreads([
    {id: 's1', isResolved: false, isOutdated: false, line: 10, originalLine: 10, startLine: v:null, originalStartLine: v:null, diffSide: 'LEFT', path: 'src/sides.ts', comments: {nodes: [{id: 'c1', body: 'x', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
    {id: 's2', isResolved: false, isOutdated: false, line: 20, originalLine: 20, startLine: v:null, originalStartLine: v:null, diffSide: 'RIGHT', path: 'src/sides.ts', comments: {nodes: [{id: 'c2', body: 'y', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
    {id: 's3', isResolved: false, isOutdated: false, line: 30, originalLine: 30, startLine: v:null, originalStartLine: v:null, diffSide: 'LEFT', path: 'src/sides.ts', comments: {nodes: [{id: 'c3', body: 'z', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
  ])

  diff.RefreshSigns()

  var left_signs = sign_getplaced(left, {group: 'gh_review'})[0].signs
  var right_signs = sign_getplaced(right, {group: 'gh_review'})[0].signs
  sort(left_signs, (a, b) => a.lnum - b.lnum)

  assert_equal(2, len(left_signs), 'LEFT should have 2 signs')
  assert_equal(10, left_signs[0].lnum)
  assert_equal(30, left_signs[1].lnum)

  assert_equal(1, len(right_signs), 'RIGHT should have 1 sign')
  assert_equal(20, right_signs[0].lnum)

  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

g:RunTest('RefreshSigns clears old signs before placing new ones', () => {
  state.Reset()

  enew
  var left = SetupBuffer('gh-review://LEFT/src/refresh.ts', 50)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/refresh.ts', 50)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/refresh.ts')

  # Place signs for 3 threads
  state.SetThreads([
    {id: 'r1', isResolved: false, isOutdated: false, line: 5, originalLine: 5, startLine: v:null, originalStartLine: v:null, diffSide: 'RIGHT', path: 'src/refresh.ts', comments: {nodes: [{id: 'c1', body: 'x', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
    {id: 'r2', isResolved: false, isOutdated: false, line: 15, originalLine: 15, startLine: v:null, originalStartLine: v:null, diffSide: 'RIGHT', path: 'src/refresh.ts', comments: {nodes: [{id: 'c2', body: 'y', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
    {id: 'r3', isResolved: false, isOutdated: false, line: 25, originalLine: 25, startLine: v:null, originalStartLine: v:null, diffSide: 'RIGHT', path: 'src/refresh.ts', comments: {nodes: [{id: 'c3', body: 'z', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
  ])
  diff.RefreshSigns()
  assert_equal(3, len(sign_getplaced(right, {group: 'gh_review'})[0].signs))

  # Now update to just 1 thread — old signs should be cleared
  state.SetThreads([
    {id: 'r1', isResolved: false, isOutdated: false, line: 5, originalLine: 5, startLine: v:null, originalStartLine: v:null, diffSide: 'RIGHT', path: 'src/refresh.ts', comments: {nodes: [{id: 'c1', body: 'x', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
  ])
  diff.RefreshSigns()

  var signs = sign_getplaced(right, {group: 'gh_review'})[0].signs
  assert_equal(1, len(signs), 'should have 1 sign after refresh')
  assert_equal(5, signs[0].lnum)

  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

g:RunTest('Thread opened by id shows correct buffer metadata', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())

  enew
  var left = SetupBuffer('gh-review://LEFT/src/new_file.ts', 50)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/new_file.ts', 50)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/new_file.ts')

  # Open thread_1 directly (as gt would do)
  thread.Open('thread_1')

  var thread_bufnr = state.GetThreadBufnr()
  assert_true(thread_bufnr != -1, 'thread buffer should be open')
  assert_equal('thread_1', getbufvar(thread_bufnr, 'gh_review_thread_id'))
  assert_equal('src/new_file.ts', getbufvar(thread_bufnr, 'gh_review_path'))
  assert_equal(10, getbufvar(thread_bufnr, 'gh_review_line'))

  thread.CloseThreadBuffer()
  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

g:RunTest('Threads for different file do not get signs', () => {
  state.Reset()

  enew
  var left = SetupBuffer('gh-review://LEFT/src/other.ts', 50)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/other.ts', 50)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/other.ts')

  # Threads on a different file path
  state.SetThreads([
    {id: 't1', isResolved: false, isOutdated: false, line: 10, originalLine: 10, startLine: v:null, originalStartLine: v:null, diffSide: 'RIGHT', path: 'src/different.ts', comments: {nodes: [{id: 'c1', body: 'x', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
  ])

  diff.RefreshSigns()

  var right_signs = sign_getplaced(right, {group: 'gh_review'})[0].signs
  assert_equal(0, len(right_signs), 'should have no signs for different file')

  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

g:RunTest('Signs for threads with line: 0 are skipped', () => {
  state.Reset()

  enew
  var left = SetupBuffer('gh-review://LEFT/src/zero.ts', 50)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/zero.ts', 50)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/zero.ts')

  # Thread with line: 0 and no originalLine
  state.SetThreads([
    {id: 'z1', isResolved: false, isOutdated: false, line: 0, originalLine: 0, startLine: v:null, originalStartLine: v:null, diffSide: 'RIGHT', path: 'src/zero.ts', comments: {nodes: [{id: 'c1', body: 'x', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
  ])

  diff.RefreshSigns()

  var right_signs = sign_getplaced(right, {group: 'gh_review'})[0].signs
  assert_equal(0, len(right_signs), 'should skip thread with line: 0')

  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

# --- Write results and exit ---

g:WriteResults('/tmp/gh_review_test_navigation.txt')
