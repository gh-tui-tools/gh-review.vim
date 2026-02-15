vim9script

# Tests for diff sign placement and thread navigation logic.
# Uses --not-a-term mode since we need real buffers for signs.

var test_dir = expand('<sfile>:p:h')
execute 'source ' .. test_dir .. '/helpers.vim'
execute 'source ' .. test_dir .. '/fixtures.vim'

import autoload 'gh_review/state.vim'
import autoload 'gh_review/diff.vim'

# Helper: create a scratch buffer with N lines of content.
def SetupBuffer(name: string, num_lines: number): number
  var bufnr = bufnr(name, true)
  execute 'buffer' bufnr
  setlocal buftype=nofile
  setlocal bufhidden=hide
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

g:RunTest('Outdated threads use originalLine for sign placement', () => {
  state.Reset()

  # Set up left and right buffers
  enew
  var left = SetupBuffer('gh-review://LEFT/src/existing.ts', 30)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/existing.ts', 30)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/existing.ts')

  # Load threads: thread_3 has line: null but originalLine: 8,
  # thread_4 has line: 5
  state.SetThreads(g:MockThreadNodes())

  diff.RefreshSigns()

  var left_signs = sign_getplaced(left, {group: 'gh_review'})[0].signs
  var right_signs = sign_getplaced(right, {group: 'gh_review'})[0].signs

  # thread_4 (line: 5, LEFT side) should produce a left sign
  assert_equal(1, len(left_signs), 'left buffer should have 1 sign')
  assert_equal(5, left_signs[0].lnum, 'sign should be at line 5')

  # thread_3 (line: null, originalLine: 8, RIGHT side) should produce a right sign
  assert_equal(1, len(right_signs), 'right buffer should have 1 sign from originalLine')
  assert_equal(8, right_signs[0].lnum, 'sign should be at originalLine 8')

  # Clean up
  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

g:RunTest('Sign types: resolved, pending, normal', () => {
  state.Reset()

  # Set up buffers for src/new_file.ts
  enew
  var left = SetupBuffer('gh-review://LEFT/src/new_file.ts', 50)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/new_file.ts', 50)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/new_file.ts')

  # Load threads: thread_1 (normal, line 10 RIGHT), thread_2 (resolved, line 25 RIGHT)
  state.SetThreads(g:MockThreadNodes())

  diff.RefreshSigns()

  var right_signs = sign_getplaced(right, {group: 'gh_review'})[0].signs
  # Sort by line number for predictable order
  sort(right_signs, (a, b) => a.lnum - b.lnum)

  assert_equal(2, len(right_signs), 'right buffer should have 2 signs')

  # thread_1: normal thread (last comment state is COMMENTED)
  assert_equal(10, right_signs[0].lnum)
  assert_equal('gh_review_thread', right_signs[0].name)

  # thread_2: resolved thread
  assert_equal(25, right_signs[1].lnum)
  assert_equal('gh_review_thread_resolved', right_signs[1].name)

  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

g:RunTest('Pending review comment gets pending sign', () => {
  state.Reset()

  # Set up buffers for src/existing.ts
  enew
  var left = SetupBuffer('gh-review://LEFT/src/existing.ts', 30)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/existing.ts', 30)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/existing.ts')

  # thread_4: line 5, LEFT side, last comment has PENDING state
  state.SetThreads(g:MockThreadNodes())

  diff.RefreshSigns()

  var left_signs = sign_getplaced(left, {group: 'gh_review'})[0].signs
  assert_equal(1, len(left_signs))
  assert_equal(5, left_signs[0].lnum)
  assert_equal('gh_review_thread_pending', left_signs[0].name)

  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

g:RunTest('RefreshSigns does nothing when diff_path is empty', () => {
  state.Reset()
  # diff_path is '' after reset, RefreshSigns should be a no-op
  diff.RefreshSigns()
  # If we get here without error, the test passes
  assert_equal('', state.GetDiffPath())
})

g:RunTest('Multiple signs placed at correct lines', () => {
  state.Reset()

  # Create left + right buffers
  enew
  var left = SetupBuffer('gh-review://LEFT/src/nav_test.ts', 50)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/nav_test.ts', 50)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/nav_test.ts')

  # Set up threads at lines 10, 25, 40 on RIGHT side
  state.SetThreads([
    {id: 'nav_1', isResolved: false, isOutdated: false, line: 10, startLine: v:null, diffSide: 'RIGHT', path: 'src/nav_test.ts', comments: {nodes: [{id: 'c1', body: 'x', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
    {id: 'nav_2', isResolved: false, isOutdated: false, line: 25, startLine: v:null, diffSide: 'RIGHT', path: 'src/nav_test.ts', comments: {nodes: [{id: 'c2', body: 'y', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
    {id: 'nav_3', isResolved: false, isOutdated: false, line: 40, startLine: v:null, diffSide: 'RIGHT', path: 'src/nav_test.ts', comments: {nodes: [{id: 'c3', body: 'z', author: {login: 'a'}, createdAt: '2025-01-01T00:00:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
  ])

  diff.RefreshSigns()

  var right_signs = sign_getplaced(right, {group: 'gh_review'})[0].signs
  sort(right_signs, (a, b) => a.lnum - b.lnum)

  assert_equal(3, len(right_signs), 'should have 3 signs on RIGHT')
  assert_equal(10, right_signs[0].lnum)
  assert_equal(25, right_signs[1].lnum)
  assert_equal(40, right_signs[2].lnum)

  # Left buffer should have no signs
  var left_signs = sign_getplaced(left, {group: 'gh_review'})[0].signs
  assert_equal(0, len(left_signs), 'LEFT should have no signs')

  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

g:RunTest('Editable buffer stores file path and mtime', () => {
  state.Reset()

  # Create a real temp file so getftime() works
  var tmpfile = '/tmp/gh_review_test_mtime.txt'
  writefile(['line 1', 'line 2', 'line 3'], tmpfile)
  var original_mtime = getftime(tmpfile)

  enew
  var left = SetupBuffer('gh-review://LEFT/test_mtime.txt', 10)
  state.SetLeftBufnr(left)
  enew
  var right_name = 'gh-review://RIGHT/test_mtime.txt'
  var right = bufnr(right_name, true)
  execute 'buffer' right
  state.SetRightBufnr(right)
  state.SetDiffPath('test_mtime.txt')
  state.SetLocalCheckout(true)

  # Simulate what SetupDiffBuffer does for editable buffers
  setlocal buftype=acwrite
  setlocal bufhidden=wipe
  setlocal noswapfile
  setlocal modifiable
  silent! deletebufline(right, 1, '$')
  setbufline(right, 1, ['line 1', 'line 2', 'line 3'])
  setlocal nomodified
  b:gh_review_file_path = tmpfile
  b:gh_review_file_mtime = original_mtime

  # Verify metadata was stored
  assert_equal(tmpfile, getbufvar(right, 'gh_review_file_path'))
  assert_equal(original_mtime, getbufvar(right, 'gh_review_file_mtime'))

  # Verify buffer content matches the file
  var buf_lines = getbufline(right, 1, '$')
  assert_equal(['line 1', 'line 2', 'line 3'], buf_lines)

  # Simulate external change: write new content and verify mtime differs
  sleep 1100m
  writefile(['changed line 1', 'line 2', 'line 3', 'line 4'], tmpfile)
  var new_mtime = getftime(tmpfile)
  assert_true(new_mtime > original_mtime, 'mtime should increase after write')

  # Simulate what CheckExternalChange does: detect the change and reload
  var cur_mtime = getftime(tmpfile)
  assert_true(cur_mtime > getbufvar(right, 'gh_review_file_mtime'), 'should detect mtime change')

  # Reload the content (as CheckExternalChange would on user confirmation)
  var new_content = readfile(tmpfile)
  setlocal modifiable
  silent! deletebufline(right, 1, '$')
  setbufline(right, 1, new_content)
  setlocal nomodified
  setbufvar(right, 'gh_review_file_mtime', cur_mtime)

  # Verify reloaded content
  buf_lines = getbufline(right, 1, '$')
  assert_equal(['changed line 1', 'line 2', 'line 3', 'line 4'], buf_lines)
  assert_equal(new_mtime, getbufvar(right, 'gh_review_file_mtime'))

  # Clean up
  delete(tmpfile)
  execute 'bwipeout!' left
  execute 'bwipeout!' right
})


g:RunTest('BufWriteCmd updates stored mtime so write is not seen as external change', () => {
  state.Reset()

  var tmpfile = '/tmp/gh_review_test_write_mtime.txt'
  writefile(['line 1', 'line 2'], tmpfile)
  var original_mtime = getftime(tmpfile)

  enew
  var left = SetupBuffer('gh-review://LEFT/test_write.txt', 10)
  state.SetLeftBufnr(left)
  enew
  var right = bufnr('gh-review://RIGHT/test_write.txt', true)
  execute 'buffer' right
  state.SetRightBufnr(right)
  state.SetDiffPath('test_write.txt')
  state.SetLocalCheckout(true)

  setlocal buftype=acwrite
  setlocal bufhidden=wipe
  setlocal noswapfile
  setlocal modifiable
  silent! deletebufline(right, 1, '$')
  setbufline(right, 1, ['line 1', 'line 2'])
  setlocal nomodified
  b:gh_review_file_path = tmpfile
  b:gh_review_file_mtime = original_mtime

  # Register BufWriteCmd that updates mtime (mirrors SetupDiffBuffer)
  execute printf('autocmd BufWriteCmd <buffer=%d> call writefile(getbufline(%d, 1, "$"), %s) | setlocal nomodified | call setbufvar(%d, "gh_review_file_mtime", getftime(%s))', right, right, string(tmpfile), right, string(tmpfile))

  # Wait so the write produces a different mtime
  sleep 1100m

  # Write via :w
  silent write

  # The stored mtime should now match the file on disk
  var disk_mtime = getftime(tmpfile)
  var stored_mtime = getbufvar(right, 'gh_review_file_mtime')
  assert_equal(disk_mtime, stored_mtime, 'stored mtime should match disk after :w')
  assert_true(stored_mtime > original_mtime, 'stored mtime should have advanced')

  # Clean up
  delete(tmpfile)
  execute 'bwipeout!' left
  execute 'bwipeout!' right
})


g:RunTest('Virtual text shows author and body', () => {
  state.Reset()

  enew
  var left = SetupBuffer('gh-review://LEFT/src/vt_test.ts', 30)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/vt_test.ts', 30)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/vt_test.ts')

  state.SetThreads([
    {id: 'vt1', isResolved: false, isOutdated: false, line: 10, originalLine: 10, startLine: v:null, originalStartLine: v:null, diffSide: 'RIGHT', path: 'src/vt_test.ts', comments: {nodes: [{id: 'c1', body: 'Looks good to me', author: {login: 'alice'}, createdAt: '2025-01-15T10:30:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
  ])

  diff.RefreshSigns()

  var props = prop_list(10, {bufnr: right})
  var has_vt = false
  for p in props
    if get(p, 'type', '') ==# 'gh_review_virt_text'
      has_vt = true
      var text = get(p, 'text', '')
      assert_match('alice', text, 'virtual text should contain author')
      assert_match('Looks good', text, 'virtual text should contain body')
    endif
  endfor
  assert_true(has_vt, 'should have virtual text property')

  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

g:RunTest('Virtual text truncates long bodies to 60 chars', () => {
  state.Reset()

  enew
  var left = SetupBuffer('gh-review://LEFT/src/trunc.ts', 30)
  state.SetLeftBufnr(left)
  enew
  var right = SetupBuffer('gh-review://RIGHT/src/trunc.ts', 30)
  state.SetRightBufnr(right)
  state.SetDiffPath('src/trunc.ts')

  var long_body = repeat('x', 100)
  state.SetThreads([
    {id: 'tr1', isResolved: false, isOutdated: false, line: 5, originalLine: 5, startLine: v:null, originalStartLine: v:null, diffSide: 'RIGHT', path: 'src/trunc.ts', comments: {nodes: [{id: 'c1', body: long_body, author: {login: 'bob'}, createdAt: '2025-01-15T10:30:00Z', pullRequestReview: {id: 'r1', state: 'COMMENTED'}}]}},
  ])

  diff.RefreshSigns()

  var props = prop_list(5, {bufnr: right})
  for p in props
    if get(p, 'type', '') ==# 'gh_review_virt_text'
      var text = get(p, 'text', '')
      assert_true(len(text) <= 66, 'virtual text should be truncated (got ' .. len(text) .. ' chars)')
      assert_match('\.\.\.', text, 'should end with ellipsis')
    endif
  endfor

  execute 'bwipeout!' left
  execute 'bwipeout!' right
})

# --- Write results and exit ---

g:WriteResults('/tmp/gh_review_test_diff_logic.txt')
