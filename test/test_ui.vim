vim9script

# Tests for UI: files list buffer and diff buffer creation.
# Uses --not-a-term mode for real Vim UI.

var test_dir = expand('<sfile>:p:h')
execute 'source ' .. test_dir .. '/helpers.vim'
execute 'source ' .. test_dir .. '/fixtures.vim'

import autoload 'gh_review/state.vim'
import autoload 'gh_review/files.vim'

# --- Tests ---

g:RunTest('Files list: Open creates buffer with correct content', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  state.SetRepoInfo('test-owner', 'test-repo')

  files.Open()

  var bufnr = state.GetFilesBufnr()
  assert_true(bufnr != -1, 'files bufnr should be set')
  assert_true(bufexists(bufnr), 'files buffer should exist')

  var lines = getbufline(bufnr, 1, '$')
  assert_true(len(lines) >= 6, 'should have header + 3 file lines')

  # Header
  assert_match('https://github.com/test-owner/test-repo/pull/42', lines[0])
  assert_match('Add feature X', lines[0])
  assert_match('Files changed (3)', lines[1])
  assert_equal('', lines[2])

  # File lines contain paths
  assert_match('src/new_file.ts', lines[3])
  assert_match('src/existing.ts', lines[4])
  assert_match('src/old_file.ts', lines[5])

  # Change type flags
  assert_match('A', lines[3])
  assert_match('M', lines[4])
  assert_match('D', lines[5])

  # Thread counts: new_file.ts has 2 threads, existing.ts has 2 threads
  assert_match('\[2 threads\]', lines[3])
  assert_match('\[2 threads\]', lines[4])

  files.Close()
})

g:RunTest('Files list: Toggle opens and closes', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  state.SetRepoInfo('test-owner', 'test-repo')

  # Toggle on
  files.Toggle()
  var bufnr = state.GetFilesBufnr()
  assert_true(bufnr != -1 && bufexists(bufnr), 'buffer should exist after toggle on')
  assert_true(bufwinid(bufnr) != -1, 'buffer should be visible after toggle on')

  # Toggle off
  files.Toggle()
  assert_equal(-1, bufwinid(bufnr), 'buffer should not be visible after toggle off')

  # Toggle on again
  files.Toggle()
  assert_true(bufwinid(bufnr) != -1, 'buffer should be visible after second toggle on')

  files.Close()
})

g:RunTest('Files list: buffer options are correct', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  state.SetRepoInfo('test-owner', 'test-repo')

  files.Open()
  var bufnr = state.GetFilesBufnr()

  assert_equal('nofile', getbufvar(bufnr, '&buftype'))
  assert_equal('hide', getbufvar(bufnr, '&bufhidden'))
  assert_false(getbufvar(bufnr, '&swapfile'))
  assert_false(getbufvar(bufnr, '&modifiable'))
  assert_equal('gh-review-files', getbufvar(bufnr, '&filetype'))

  files.Close()
})

g:RunTest('Files list: additions and deletions shown', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  state.SetRepoInfo('test-owner', 'test-repo')

  files.Open()
  var bufnr = state.GetFilesBufnr()
  var lines = getbufline(bufnr, 1, '$')

  # new_file.ts: +50 -0
  assert_match('+50', lines[3])
  assert_match('-0', lines[3])

  # existing.ts: +10 -5
  assert_match('+10', lines[4])
  assert_match('-5', lines[4])

  # old_file.ts: +0 -30
  assert_match('+0', lines[5])
  assert_match('-30', lines[5])

  files.Close()
})

g:RunTest('Files list: Rerender updates content', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  state.SetRepoInfo('test-owner', 'test-repo')

  files.Open()
  var bufnr = state.GetFilesBufnr()

  # Add a new thread to old_file.ts
  state.SetThread('thread_extra', {id: 'thread_extra', isResolved: false, isOutdated: false, line: 1, startLine: v:null, diffSide: 'RIGHT', path: 'src/old_file.ts', comments: {nodes: []}})

  files.Rerender()

  var lines = getbufline(bufnr, 1, '$')
  # old_file.ts now has 1 thread
  assert_match('\[1 thread\]', lines[5])

  files.Close()
})

g:RunTest('Files list: Close expands diff windows into freed space', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  state.SetRepoInfo('test-owner', 'test-repo')

  # Open files list, then simulate diff windows above it
  files.Open()
  var files_bufnr = state.GetFilesBufnr()
  var files_winid = bufwinid(files_bufnr)
  assert_true(files_winid != -1, 'files window should exist')

  # Create two vertically-split buffers above the files list to act as
  # left and right diff buffers
  win_gotoid(files_winid)
  aboveleft new
  var right_bufnr = bufnr('gh-review://RIGHT/test.ts', true)
  execute 'buffer' right_bufnr
  setlocal buftype=nofile
  setlocal scrollbind
  state.SetRightBufnr(right_bufnr)

  aboveleft vnew
  var left_bufnr = bufnr('gh-review://LEFT/test.ts', true)
  execute 'buffer' left_bufnr
  setlocal buftype=nofile
  setlocal scrollbind
  state.SetLeftBufnr(left_bufnr)

  # Record total editor height and files window height
  var total_height = &lines - &cmdheight - 1
  var files_height = winheight(files_winid)
  var left_height_before = winheight(bufwinid(left_bufnr))
  var right_height_before = winheight(bufwinid(right_bufnr))

  # Close the files list
  files.Close()

  # The files window should be gone
  assert_equal(-1, bufwinid(files_bufnr), 'files window should be closed')

  # Diff windows should have grown
  var left_height_after = winheight(bufwinid(left_bufnr))
  var right_height_after = winheight(bufwinid(right_bufnr))
  assert_true(left_height_after > left_height_before, 'left diff should be taller after close')
  assert_true(right_height_after > right_height_before, 'right diff should be taller after close')

  # Clean up
  execute 'bwipeout!' left_bufnr
  execute 'bwipeout!' right_bufnr
})

g:RunTest('Files list: gf keymap closes the files list', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  state.SetRepoInfo('test-owner', 'test-repo')

  files.Open()
  var bufnr = state.GetFilesBufnr()
  assert_true(bufwinid(bufnr) != -1, 'files window should be visible')

  # gf is a buffer-local mapping that calls Close()
  var winid = bufwinid(bufnr)
  win_gotoid(winid)
  execute "normal gf"

  assert_equal(-1, bufwinid(bufnr), 'files window should be closed after gf')
})


g:RunTest('Files list: all change type flags rendered correctly', () => {
  state.Reset()
  state.SetPR(g:MockAllChangeTypesPRData())
  state.SetThreads([])
  state.SetRepoInfo('test-owner', 'test-repo')

  files.Open()
  var bufnr = state.GetFilesBufnr()
  var lines = getbufline(bufnr, 1, '$')

  assert_match('Files changed (5)', lines[1])

  # Each line should have the correct single-char flag
  assert_match('\sA\s', lines[3], 'ADDED should show A flag')
  assert_match('\sM\s', lines[4], 'MODIFIED should show M flag')
  assert_match('\sD\s', lines[5], 'DELETED should show D flag')
  assert_match('\sR\s', lines[6], 'RENAMED should show R flag')
  assert_match('\sC\s', lines[7], 'COPIED should show C flag')

  files.Close()
})

# --- Write results and exit ---

g:WriteResults('/tmp/gh_review_test_ui.txt')
