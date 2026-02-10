vim9script

# Tests for thread buffer: content rendering, metadata, buffer options,
# code context, and close behaviour.

var test_dir = expand('<sfile>:p:h')
execute 'source ' .. test_dir .. '/helpers.vim'
execute 'source ' .. test_dir .. '/fixtures.vim'

import autoload 'gh_review/state.vim'
import autoload 'gh_review/thread.vim'

# Helper: create mock left/right buffers so ShowThread can show code context.
def SetupDiffBuffers(path: string, num_lines: number)
  var left_name = 'gh-review://LEFT/' .. path
  var right_name = 'gh-review://RIGHT/' .. path

  enew
  var left = bufnr(left_name, true)
  execute 'buffer' left
  setlocal buftype=nofile noswapfile bufhidden=hide modifiable
  var lines: list<string> = []
  for i in range(1, num_lines)
    add(lines, 'line ' .. i)
  endfor
  deletebufline(left, 1, '$')
  setbufline(left, 1, lines)
  setlocal nomodifiable
  state.SetLeftBufnr(left)

  enew
  var right = bufnr(right_name, true)
  execute 'buffer' right
  setlocal buftype=nofile noswapfile bufhidden=hide modifiable
  deletebufline(right, 1, '$')
  setbufline(right, 1, lines)
  setlocal nomodifiable
  state.SetRightBufnr(right)
enddef

def CleanupDiffBuffers()
  var left = state.GetLeftBufnr()
  var right = state.GetRightBufnr()
  if left != -1 && bufexists(left)
    execute 'bwipeout!' left
  endif
  if right != -1 && bufexists(right)
    execute 'bwipeout!' right
  endif
  state.SetLeftBufnr(-1)
  state.SetRightBufnr(-1)
enddef

# --- Tests ---

g:RunTest('Thread buffer: existing thread renders header and comments', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  # Open thread_1: unresolved, line 10, RIGHT, 1 comment by alice
  thread.Open('thread_1')

  var bufnr = state.GetThreadBufnr()
  assert_true(bufnr != -1, 'thread bufnr should be set')
  assert_true(bufexists(bufnr), 'thread buffer should exist')

  var lines = getbufline(bufnr, 1, '$')
  var all_text = join(lines, "\n")

  # Header
  assert_match('Thread on', lines[0])
  assert_match('src/new_file.ts', lines[0])
  assert_match(':10', lines[0])
  assert_match('\[Active\]', lines[0])

  # Comment
  assert_match('alice', all_text)
  assert_match('2025-01-15', all_text)
  assert_match('Looks good', all_text)

  # Reply separator
  assert_match('Reply below', all_text)

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: resolved thread shows Resolved status', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  thread.Open('thread_2')

  var bufnr = state.GetThreadBufnr()
  var lines = getbufline(bufnr, 1, '$')
  var all_text = join(lines, "\n")

  assert_match('\[Resolved\]', lines[0])

  # Both comments present
  assert_match('bob', all_text)
  assert_match('Fix this', all_text)
  assert_match('alice', all_text)
  assert_match('Done', all_text)

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: new comment renders New header', () => {
  state.Reset()
  SetupDiffBuffers('src/test.ts', 20)
  state.SetDiffPath('src/test.ts')

  # Pass a body to avoid startinsert (which crashes headless Vim)
  thread.OpenNew('src/test.ts', 5, 5, 'RIGHT', 'placeholder')

  var bufnr = state.GetThreadBufnr()
  var lines = getbufline(bufnr, 1, '$')

  assert_match('New comment on', lines[0])
  assert_match('src/test.ts', lines[0])
  assert_match(':5', lines[0])
  assert_match('\[New\]', lines[0])

  assert_true(getbufvar(bufnr, 'gh_review_is_new'))

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: metadata variables set correctly', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  thread.Open('thread_1')
  var bufnr = state.GetThreadBufnr()

  assert_equal('thread_1', getbufvar(bufnr, 'gh_review_thread_id'))
  assert_equal('src/new_file.ts', getbufvar(bufnr, 'gh_review_path'))
  assert_equal(10, getbufvar(bufnr, 'gh_review_line'))
  assert_equal('RIGHT', getbufvar(bufnr, 'gh_review_side'))
  assert_false(getbufvar(bufnr, 'gh_review_is_new'))
  assert_false(getbufvar(bufnr, 'gh_review_is_resolved'))
  assert_equal('comment_1', getbufvar(bufnr, 'gh_review_first_comment_id'))

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: resolved thread metadata', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  thread.Open('thread_2')
  var bufnr = state.GetThreadBufnr()

  assert_true(getbufvar(bufnr, 'gh_review_is_resolved'))
  assert_equal('comment_2', getbufvar(bufnr, 'gh_review_first_comment_id'))

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: outdated thread falls back to originalLine', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/existing.ts', 30)
  state.SetDiffPath('src/existing.ts')

  # thread_3 has line: null, originalLine: 8
  thread.Open('thread_3')
  var bufnr = state.GetThreadBufnr()

  assert_equal(8, getbufvar(bufnr, 'gh_review_line'))
  assert_match(':8', getbufline(bufnr, 1, 1)[0])

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: buffer options are correct', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  thread.Open('thread_1')
  var bufnr = state.GetThreadBufnr()

  assert_equal('acwrite', getbufvar(bufnr, '&buftype'))
  assert_equal('wipe', getbufvar(bufnr, '&bufhidden'))
  assert_false(getbufvar(bufnr, '&swapfile'))
  assert_equal('gh-review-thread', getbufvar(bufnr, '&filetype'))
  assert_true(getbufvar(bufnr, '&wrap'))

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: close cleans up state', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  thread.Open('thread_1')
  assert_true(state.GetThreadBufnr() != -1, 'thread bufnr should be set before close')

  thread.CloseThreadBuffer()

  assert_equal(-1, state.GetThreadBufnr(), 'thread bufnr should be -1 after close')
  assert_equal(-1, state.GetThreadWinid(), 'thread winid should be -1 after close')

  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: initial body (suggestion) rendered', () => {
  state.Reset()
  SetupDiffBuffers('src/test.ts', 20)
  state.SetDiffPath('src/test.ts')

  var suggestion = "```suggestion\nsome code\n```"
  thread.OpenNew('src/test.ts', 5, 5, 'RIGHT', suggestion)

  var bufnr = state.GetThreadBufnr()
  var lines = getbufline(bufnr, 1, '$')
  var all_text = join(lines, "\n")

  assert_match('suggestion', all_text)
  assert_match('some code', all_text)

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: code context from right buffer uses + prefix', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  # thread_1 is on line 10, RIGHT side
  thread.Open('thread_1')

  var bufnr = state.GetThreadBufnr()
  var lines = getbufline(bufnr, 1, '$')
  var all_text = join(lines, "\n")

  assert_match('10 +', all_text)

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: multi-line thread shows range context', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  # thread_2 has startLine: 20, line: 25
  thread.Open('thread_2')

  var bufnr = state.GetThreadBufnr()
  var lines = getbufline(bufnr, 1, '$')
  var all_text = join(lines, "\n")

  assert_match('20 +', all_text)
  assert_match('25 +', all_text)

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: LEFT side uses - prefix in context', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/existing.ts', 30)
  state.SetDiffPath('src/existing.ts')

  # thread_4 is on line 5, LEFT side
  thread.Open('thread_4')

  var bufnr = state.GetThreadBufnr()
  var lines = getbufline(bufnr, 1, '$')
  var all_text = join(lines, "\n")

  assert_match('5 -', all_text)

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: date formatting strips time portion', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  thread.Open('thread_1')

  var bufnr = state.GetThreadBufnr()
  var lines = getbufline(bufnr, 1, '$')
  var all_text = join(lines, "\n")

  assert_match('2025-01-15', all_text)
  assert_false(all_text =~# 'T10:30', 'should not contain time portion')

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: opening new thread closes previous one', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  thread.Open('thread_1')
  var first_bufnr = state.GetThreadBufnr()
  assert_true(first_bufnr != -1)

  # Open a second thread — the first should be closed
  thread.Open('thread_2')
  var second_bufnr = state.GetThreadBufnr()
  assert_true(second_bufnr != -1)
  assert_false(bufexists(first_bufnr), 'first thread buffer should be wiped')

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: close expands diff windows into freed space', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  state.SetDiffPath('src/new_file.ts')

  # Create a visible two-pane layout (left | right) so both have windows
  var lines: list<string> = []
  for i in range(1, 30)
    add(lines, 'line ' .. i)
  endfor

  enew
  var right_bufnr = bufnr('gh-review://RIGHT/src/new_file.ts', true)
  execute 'buffer' right_bufnr
  setlocal buftype=nofile noswapfile bufhidden=hide modifiable scrollbind
  deletebufline(right_bufnr, 1, '$')
  setbufline(right_bufnr, 1, lines)
  setlocal nomodifiable
  state.SetRightBufnr(right_bufnr)

  aboveleft vnew
  var left_bufnr = bufnr('gh-review://LEFT/src/new_file.ts', true)
  execute 'buffer' left_bufnr
  setlocal buftype=nofile noswapfile bufhidden=hide modifiable scrollbind
  deletebufline(left_bufnr, 1, '$')
  setbufline(left_bufnr, 1, lines)
  setlocal nomodifiable
  state.SetLeftBufnr(left_bufnr)

  # Open thread — creates a bottom split, shrinking the diff windows
  thread.Open('thread_1')

  var left_height_before = winheight(bufwinid(left_bufnr))
  var right_height_before = winheight(bufwinid(right_bufnr))

  thread.CloseThreadBuffer()

  var left_height_after = winheight(bufwinid(left_bufnr))
  var right_height_after = winheight(bufwinid(right_bufnr))
  assert_true(left_height_after > left_height_before, 'left diff should be taller after thread close')
  assert_true(right_height_after > right_height_before, 'right diff should be taller after thread close')

  execute 'bwipeout!' left_bufnr
  execute 'bwipeout!' right_bufnr
})

g:RunTest('Thread buffer: reply_start points to line after separator', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  thread.Open('thread_1')
  var bufnr = state.GetThreadBufnr()
  var reply_start = getbufvar(bufnr, 'gh_review_reply_start')

  # reply_start should be a positive number
  assert_true(reply_start > 0, 'reply_start should be positive')

  # The line just before reply_start should be the separator
  var sep_line = getbufline(bufnr, reply_start - 1, reply_start - 1)[0]
  assert_match('Reply below', sep_line, 'line before reply_start should be the separator')

  # The line at reply_start should be blank (ready for input)
  var reply_line = getbufline(bufnr, reply_start, reply_start)[0]
  assert_equal('', reply_line, 'reply_start line should be blank')

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: reply area is editable', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  thread.Open('thread_1')
  var bufnr = state.GetThreadBufnr()
  var reply_start = getbufvar(bufnr, 'gh_review_reply_start')

  # Move cursor to reply area and verify modifiable
  var winid = bufwinid(bufnr)
  win_gotoid(winid)
  cursor(reply_start, 1)
  execute "doautocmd CursorMoved"
  assert_true(getbufvar(bufnr, '&modifiable'), 'reply area should be modifiable')

  # Write some text into the reply area
  setbufline(bufnr, reply_start, 'Test reply text')
  var written = getbufline(bufnr, reply_start, reply_start)[0]
  assert_equal('Test reply text', written, 'should be able to write in reply area')

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

g:RunTest('Thread buffer: header area is read-only', () => {
  state.Reset()
  state.SetPR(g:MockPRData())
  state.SetThreads(g:MockThreadNodes())
  SetupDiffBuffers('src/new_file.ts', 30)
  state.SetDiffPath('src/new_file.ts')

  thread.Open('thread_1')
  var bufnr = state.GetThreadBufnr()

  # Move cursor to header (line 1) and verify nomodifiable
  var winid = bufwinid(bufnr)
  win_gotoid(winid)
  cursor(1, 1)
  execute "doautocmd CursorMoved"
  assert_false(getbufvar(bufnr, '&modifiable'), 'header area should not be modifiable')

  thread.CloseThreadBuffer()
  CleanupDiffBuffers()
})

# --- Write results and exit ---

g:WriteResults('/tmp/gh_review_test_thread.txt')
