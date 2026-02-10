vim9script

# Changed files list buffer.

import autoload 'gh_review/state.vim'
import autoload 'gh_review/diff.vim'

const BUF_NAME = 'gh-review://files'

# Render the files list and open in a bottom split.
export def Open()
  # Reuse existing buffer if it exists
  var bufnr = state.GetFilesBufnr()
  if bufnr != -1 && bufexists(bufnr)
    var winid = bufwinid(bufnr)
    if winid != -1
      win_gotoid(winid)
      Render()
      return
    endif
  endif

  # Create a new split at the bottom
  botright new
  resize 12
  var new_bufnr = bufnr(BUF_NAME, true)
  execute 'buffer' new_bufnr
  state.SetFilesBufnr(new_bufnr)

  SetupBuffer()
  Render()
enddef

export def Close()
  var bufnr = state.GetFilesBufnr()
  if bufnr != -1 && bufexists(bufnr)
    var winid = bufwinid(bufnr)
    if winid != -1
      win_gotoid(winid)
      close
      # Let diff windows expand into the freed space and redraw.
      # In diff/scrollbind mode, the viewport doesn't update to fill
      # the new window height. Nudge each window's scroll position to
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
    endif
  endif
enddef

export def Toggle()
  var bufnr = state.GetFilesBufnr()
  if bufnr != -1 && bufexists(bufnr) && bufwinid(bufnr) != -1
    Close()
  else
    Open()
  endif
enddef

def SetupBuffer()
  setlocal buftype=nofile
  setlocal bufhidden=hide
  setlocal noswapfile
  setlocal nomodifiable
  setlocal nowrap
  setlocal nonumber
  setlocal norelativenumber
  setlocal signcolumn=no
  setlocal nolist
  setlocal filetype=gh-review-files
  setlocal winfixheight

  # Keymaps
  nnoremap <buffer> <silent> <CR> <ScriptCmd>OpenFileUnderCursor()<CR>
  nnoremap <buffer> <silent> q <ScriptCmd>Close()<CR>
  nnoremap <buffer> <silent> gf <ScriptCmd>Close()<CR>
  nnoremap <buffer> <silent> R <ScriptCmd>RefreshAndRender()<CR>
enddef

def RefreshAndRender()
  import autoload 'gh_review.vim' as orchestrator
  orchestrator.RefreshThreads()
enddef

def Render()
  var files = state.GetChangedFiles()
  var lines: list<string> = []
  var pr_title = state.GetPRTitle()
  var pr_number = state.GetPRNumber()
  var pr_url = printf('https://github.com/%s/%s/pull/%d', state.GetOwner(), state.GetName(), pr_number)
  add(lines, printf('%s: %s', pr_url, pr_title))
  add(lines, printf('Files changed (%d)', len(files)))
  add(lines, '')

  for f in files
    var status = ChangeTypeToFlag(get(f, 'changeType', 'MODIFIED'))
    var additions = get(f, 'additions', 0)
    var deletions = get(f, 'deletions', 0)
    var path = get(f, 'path', '')

    # Count threads for this file
    var file_threads = state.GetThreadsForFile(path)
    var thread_count = len(file_threads)
    var thread_info = thread_count > 0 ? printf('  [%d thread%s]', thread_count, thread_count > 1 ? 's' : '') : ''

    add(lines, printf('  +%-4d -%-4d %s  %s%s', additions, deletions, status, path, thread_info))
  endfor

  setlocal modifiable
  deletebufline(state.GetFilesBufnr(), 1, '$')
  setbufline(state.GetFilesBufnr(), 1, lines)
  setlocal nomodifiable

  # Position cursor on first file line
  cursor(4, 1)
enddef

export def Rerender()
  var bufnr = state.GetFilesBufnr()
  if bufnr != -1 && bufexists(bufnr)
    var winid = bufwinid(bufnr)
    if winid != -1
      var save_winid = win_getid()
      win_gotoid(winid)
      Render()
      win_gotoid(save_winid)
    endif
  endif
enddef

def ChangeTypeToFlag(change_type: string): string
  if change_type ==# 'ADDED'
    return 'A'
  elseif change_type ==# 'DELETED'
    return 'D'
  elseif change_type ==# 'RENAMED'
    return 'R'
  elseif change_type ==# 'COPIED'
    return 'C'
  endif
  return 'M'
enddef

def OpenFileUnderCursor()
  var lnum = line('.')
  # First 3 lines are header
  if lnum <= 3
    return
  endif
  var file_idx = lnum - 4
  var files = state.GetChangedFiles()
  if file_idx < 0 || file_idx >= len(files)
    return
  endif
  var path = files[file_idx].path
  diff.Open(path)
enddef
