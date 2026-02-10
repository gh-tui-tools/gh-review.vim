vim9script

# Side-by-side diff view with review thread signs.

import autoload 'gh_review/state.vim'
import autoload 'gh_review/thread.vim'
import autoload 'gh_review/api.vim'
import autoload 'gh_review/files.vim'

const SID = expand('<SID>')

# Get the effective line number for a thread, falling back to originalLine
# for outdated threads where line is null.
def GetThreadLine(t: dict<any>): number
  var raw = get(t, 'line', v:null)
  if raw != v:null && type(raw) == v:t_number && raw > 0
    return raw
  endif
  var orig = get(t, 'originalLine', v:null)
  if orig != v:null && type(orig) == v:t_number && orig > 0
    return orig
  endif
  return 0
enddef

# Remove a trailing empty string from split() output.
def TrimTrailingEmpty(lines: list<string>)
  if !empty(lines) && lines[-1] ==# ''
    remove(lines, -1)
  endif
enddef

# Open a side-by-side diff for the given file path.
export def Open(path: string)
  state.SetDiffPath(path)

  var base_oid = state.GetMergeBaseOid()
  if empty(base_oid)
    base_oid = state.GetBaseOid()
  endif
  var head_oid = state.GetHeadOid()

  # Try fetching file contents via git show (local)
  FetchContents(base_oid, head_oid, path)
enddef

def FetchContents(base_oid: string, head_oid: string, path: string)
  # Determine change type for this file
  var change_type = 'MODIFIED'
  for f in state.GetChangedFiles()
    if f.path ==# path
      change_type = get(f, 'changeType', 'MODIFIED')
      break
    endif
  endfor

  var left_content: list<string> = []
  var right_content: list<string> = []
  var fetches_done = 0
  var total_fetches = 2

  var HandleDone = () => {
    fetches_done += 1
    if fetches_done >= total_fetches
      timer_start(0, (_) => ShowDiff(path, left_content, right_content))
    endif
  }

  # Fetch left (base) content
  if change_type ==# 'ADDED'
    left_content = []
    fetches_done += 1
  else
    FetchGitContent(base_oid, path, (content) => {
      left_content = content
      HandleDone()
    })
  endif

  # Fetch right (head) content
  if change_type ==# 'DELETED'
    right_content = []
    fetches_done += 1
  else
    FetchGitContent(head_oid, path, (content) => {
      right_content = content
      HandleDone()
    })
  endif

  # Check if both were synchronous (ADDED/DELETED)
  if fetches_done >= total_fetches
    timer_start(0, (_) => ShowDiff(path, left_content, right_content))
  endif
enddef

def FetchGitContent(ref: string, path: string, Callback: func(list<string>))
  var cmd = printf('git show %s:%s', shellescape(ref), shellescape(path))
  var stdout_lines: list<string> = []
  var stderr_lines: list<string> = []

  job_start(['bash', '-c', cmd], {
    out_mode: 'raw',
    err_mode: 'raw',
    out_cb: (ch, msg) => {
      add(stdout_lines, msg)
    },
    err_cb: (ch, msg) => {
      add(stderr_lines, msg)
    },
    exit_cb: (j, status) => {
      if status != 0
        # Fall back to GraphQL blob query
        FetchGraphQLContent(ref, path, Callback)
        return
      endif
      var content = split(join(stdout_lines, ''), "\n", true)
      TrimTrailingEmpty(content)
      timer_start(0, (_) => Callback(content))
    },
  })
enddef

def FetchGraphQLContent(ref: string, path: string, Callback: func(list<string>))
  var owner = state.GetOwner()
  var name = state.GetName()
  var query_lines =<< trim GRAPHQL
    query($owner: String!, $name: String!, $expression: String!) {
      repository(owner: $owner, name: $name) {
        object(expression: $expression) {
          ... on Blob {
            text
          }
        }
      }
    }
  GRAPHQL
  var query = join(query_lines, "\n")

  var gql_vars: dict<any> = {
    owner: owner,
    name: name,
    expression: ref .. ':' .. path,
  }
  api.GraphQL(query, gql_vars, (result) => {
    var data = get(result, 'data', {})
    var repo = type(data) == v:t_dict ? get(data, 'repository', {}) : {}
    var obj = type(repo) == v:t_dict ? get(repo, 'object', {}) : {}
    var text = type(obj) == v:t_dict ? get(obj, 'text', '') : ''
    var content = split(text, "\n", true)
    TrimTrailingEmpty(content)
    Callback(content)
  })
enddef

def ShowDiff(path: string, left_content: list<string>, right_content: list<string>)
  var left_name = 'gh-review://LEFT/' .. path
  var right_name = 'gh-review://RIGHT/' .. path

  # Clean up existing left diff window
  var old_left = state.GetLeftBufnr()
  if old_left != -1 && bufexists(old_left)
    var winid = bufwinid(old_left)
    if winid != -1
      win_gotoid(winid)
      close
    endif
  endif

  # Find target window: reuse existing right, or go above files list
  var old_right = state.GetRightBufnr()
  if old_right != -1 && bufexists(old_right) && bufwinid(old_right) != -1
    win_gotoid(bufwinid(old_right))
    diffoff
  else
    var files_bufnr = state.GetFilesBufnr()
    var files_winid = files_bufnr != -1 ? bufwinid(files_bufnr) : -1
    if files_winid != -1
      win_gotoid(files_winid)
      wincmd k
      # If we didn't move, files is the only window — split above it
      if win_getid() == files_winid
        aboveleft new
      endif
    endif
  endif

  # Set up the right (head) buffer.
  # Use noautocmd to prevent filetype detection from the buffer name,
  # which would trigger FileType autocmds and cause plugins (vim-lsp,
  # ALE, ftplugins) to attach and asynchronously reset fold options.
  var right_bufnr = bufnr(right_name, true)
  noautocmd execute 'buffer' right_bufnr
  state.SetRightBufnr(right_bufnr)
  SetupDiffBuffer(right_bufnr, right_name, path, right_content, state.IsLocalCheckout())

  # Set up the left (base) buffer in a vertical split
  noautocmd aboveleft vnew
  var left_bufnr = bufnr(left_name, true)
  noautocmd execute 'buffer' left_bufnr
  state.SetLeftBufnr(left_bufnr)
  SetupDiffBuffer(left_bufnr, left_name, path, left_content)

  # Enable diff mode on both — left window first, then right
  wincmd p
  diffthis
  setlocal wrap
  setlocal foldlevel=0
  wincmd p
  diffthis
  setlocal wrap
  setlocal foldlevel=0

  # Place signs for review threads
  PlaceSigns(path)

  # Position cursor in the right (head) window at the top
  win_gotoid(bufwinid(right_bufnr))
  normal! gg
enddef

def WriteBuffer(bufnr: number, path: string)
  writefile(getbufline(bufnr, 1, '$'), path)
  setlocal nomodified
  setbufvar(bufnr, 'gh_review_file_mtime', getftime(path))
  echo printf('"%s" %dL, %dB written', path, line('$'), getfsize(path))
enddef

def CheckExternalChange(bufnr: number)
  var path = getbufvar(bufnr, 'gh_review_file_path', '')
  if empty(path)
    return
  endif
  var old_mtime = getbufvar(bufnr, 'gh_review_file_mtime', 0)
  var cur_mtime = getftime(path)
  if cur_mtime <= old_mtime
    return
  endif
  setbufvar(bufnr, 'gh_review_file_mtime', cur_mtime)
  inputsave()
  var choice = input(printf('%s changed on disk. Reload? (Y/n) ', path))
  inputrestore()
  if choice ==? 'n'
    echo ''
    redraw
    return
  endif
  var new_content = readfile(path)
  var winid = bufwinid(bufnr)
  if winid != -1
    win_gotoid(winid)
  endif
  setlocal modifiable
  silent! deletebufline(bufnr, 1, '$')
  setbufline(bufnr, 1, new_content)
  setlocal nomodified
  diffupdate
  redraw
  echo 'Reloaded from disk'
enddef

def SetupDiffBuffer(bufnr: number, name: string, path: string, content: list<string>, editable: bool = false)
  if editable
    setlocal buftype=acwrite
  else
    setlocal buftype=nofile
  endif
  setlocal bufhidden=wipe
  setlocal noswapfile
  setlocal modifiable
  silent! deletebufline(bufnr, 1, '$')
  setbufline(bufnr, 1, content)
  if editable
    setlocal nomodified
    b:gh_review_file_path = path
    b:gh_review_file_mtime = getftime(path)
    execute printf('autocmd BufWriteCmd <buffer=%d> call %sWriteBuffer(%d, %s)', bufnr, SID, bufnr, string(path))
    execute printf('autocmd FocusGained,BufEnter,CursorHold <buffer=%d> call %sCheckExternalChange(%d)', bufnr, SID, bufnr)
  else
    setlocal nomodifiable
  endif

  # Set syntax highlighting from path extension.
  # Use syntax= instead of filetype= to avoid triggering FileType autocmds,
  # which would cause vim-lsp/ALE to attach and asynchronously reset fold
  # options on these read-only diff buffers.
  var ext = fnamemodify(path, ':e')
  if !empty(ext)
    var syntax_map: dict<string> = {
      ts: 'typescript',
      tsx: 'typescriptreact',
      js: 'javascript',
      jsx: 'javascriptreact',
      py: 'python',
      rb: 'ruby',
      rs: 'rust',
      go: 'go',
      java: 'java',
      kt: 'kotlin',
      kts: 'kotlin',
      swift: 'swift',
      php: 'php',
      lua: 'lua',
      pl: 'perl',
      pm: 'perl',
      sh: 'sh',
      bash: 'sh',
      zsh: 'zsh',
      vim: 'vim',
      el: 'lisp',
      ex: 'elixir',
      exs: 'elixir',
      erl: 'erlang',
      hs: 'haskell',
      scala: 'scala',
      r: 'r',
      yml: 'yaml',
      md: 'markdown',
      h: 'c',
      hpp: 'cpp',
      cc: 'cpp',
      cxx: 'cpp',
      cs: 'cs',
      m: 'objc',
      mm: 'objcpp',
    }
    execute 'setlocal syntax=' .. get(syntax_map, ext, ext)
  endif

  setlocal foldmethod=diff
  setlocal signcolumn=yes

  # Mark buffer so the fold guard can identify it
  b:gh_review_diff = true

  # Diff-buffer-local keymaps
  nnoremap <buffer> <silent> gt <ScriptCmd>OpenThreadAtCursor()<CR>
  nnoremap <buffer> <silent> gc <ScriptCmd>CreateCommentAtCursor()<CR>
  xnoremap <buffer> <silent> gc <ScriptCmd>CreateCommentVisual()<CR>
  nnoremap <buffer> <silent> ]t <ScriptCmd>JumpToNextThread()<CR>
  nnoremap <buffer> <silent> [t <ScriptCmd>JumpToPrevThread()<CR>
  nnoremap <buffer> <silent> gs <ScriptCmd>CreateSuggestionAtCursor()<CR>
  xnoremap <buffer> <silent> gs <ScriptCmd>CreateSuggestionVisual()<CR>
  nnoremap <buffer> <silent> gf <ScriptCmd>files.Toggle()<CR>
  nnoremap <buffer> <silent> q <ScriptCmd>CloseDiff()<CR>
enddef

def GetCurrentSide(): string
  if bufnr('%') == state.GetLeftBufnr()
    return 'LEFT'
  endif
  return 'RIGHT'
enddef

def PlaceSigns(path: string)
  var file_threads = state.GetThreadsForFile(path)
  var left_bufnr = state.GetLeftBufnr()
  var right_bufnr = state.GetRightBufnr()

  # Clear existing signs
  if left_bufnr != -1 && bufexists(left_bufnr)
    sign_unplace('gh_review', {buffer: left_bufnr})
  endif
  if right_bufnr != -1 && bufexists(right_bufnr)
    sign_unplace('gh_review', {buffer: right_bufnr})
  endif

  var sign_id = 1
  for t in file_threads
    var line: number = GetThreadLine(t)
    if line <= 0
      continue
    endif

    var side = get(t, 'diffSide', 'RIGHT')
    var target_bufnr = side ==# 'LEFT' ? left_bufnr : right_bufnr
    if target_bufnr == -1 || !bufexists(target_bufnr)
      continue
    endif

    var is_resolved = get(t, 'isResolved', false)
    var is_pending = false
    var comments = get(get(t, 'comments', {}), 'nodes', [])
    if !empty(comments)
      var last_comment = comments[-1]
      var review = get(last_comment, 'pullRequestReview', {})
      if !empty(review) && get(review, 'state', '') ==# 'PENDING'
        is_pending = true
      endif
    endif

    var sign_name = 'gh_review_thread'
    if is_pending
      sign_name = 'gh_review_thread_pending'
    elseif is_resolved
      sign_name = 'gh_review_thread_resolved'
    endif

    sign_place(sign_id, 'gh_review', sign_name, target_bufnr, {lnum: line})
    sign_id += 1
  endfor
enddef

export def RefreshSigns()
  var path = state.GetDiffPath()
  if !empty(path)
    PlaceSigns(path)
  endif
enddef

def OpenThreadAtCursor()
  var lnum = line('.')
  var side = GetCurrentSide()
  var path = state.GetDiffPath()
  var file_threads = state.GetThreadsForFile(path)

  for t in file_threads
    var thread_line: number = GetThreadLine(t)
    if thread_line <= 0
      continue
    endif
    var thread_side = get(t, 'diffSide', 'RIGHT')
    if thread_line == lnum && thread_side ==# side
      thread.Open(t.id)
      return
    endif
  endfor

  echo 'No thread at this line'
enddef

def CreateCommentAtCursor()
  var lnum = line('.')
  var side = GetCurrentSide()
  var path = state.GetDiffPath()
  thread.OpenNew(path, lnum, lnum, side)
enddef

def CreateCommentVisual()
  var start_lnum = min([line('v'), line('.')])
  var end_lnum = max([line('v'), line('.')])
  var side = GetCurrentSide()
  var path = state.GetDiffPath()
  thread.OpenNew(path, start_lnum, end_lnum, side)
enddef

def CreateSuggestionAtCursor()
  if GetCurrentSide() !=# 'RIGHT'
    echo 'Suggestions are only available in the head (right) buffer'
    return
  endif
  var lnum = line('.')
  var path = state.GetDiffPath()
  var code_line = getline(lnum)
  var suggestion = "```suggestion\n" .. code_line .. "\n```"
  thread.OpenNew(path, lnum, lnum, 'RIGHT', suggestion)
enddef

def CreateSuggestionVisual()
  if GetCurrentSide() !=# 'RIGHT'
    echo 'Suggestions are only available in the head (right) buffer'
    return
  endif
  var start_lnum = min([line('v'), line('.')])
  var end_lnum = max([line('v'), line('.')])
  var path = state.GetDiffPath()
  var buf_lines = getline(start_lnum, end_lnum)
  var suggestion = "```suggestion\n" .. join(buf_lines, "\n") .. "\n```"
  thread.OpenNew(path, start_lnum, end_lnum, 'RIGHT', suggestion)
enddef

def JumpToNextThread()
  var lnum = line('.')
  var side = GetCurrentSide()
  var path = state.GetDiffPath()
  var file_threads = state.GetThreadsForFile(path)

  var next_line = 999999
  for t in file_threads
    var thread_line: number = GetThreadLine(t)
    if thread_line <= 0
      continue
    endif
    var thread_side = get(t, 'diffSide', 'RIGHT')
    if thread_side ==# side && thread_line > lnum && thread_line < next_line
      next_line = thread_line
    endif
  endfor

  if next_line < 999999
    cursor(next_line, 1)
  else
    echo 'No more threads'
  endif
enddef

def JumpToPrevThread()
  var lnum = line('.')
  var side = GetCurrentSide()
  var path = state.GetDiffPath()
  var file_threads = state.GetThreadsForFile(path)

  var prev_line = 0
  for t in file_threads
    var thread_line: number = GetThreadLine(t)
    if thread_line <= 0
      continue
    endif
    var thread_side = get(t, 'diffSide', 'RIGHT')
    if thread_side ==# side && thread_line < lnum && thread_line > prev_line
      prev_line = thread_line
    endif
  endfor

  if prev_line > 0
    cursor(prev_line, 1)
  else
    echo 'No more threads'
  endif
enddef

export def CloseDiff()
  var left = state.GetLeftBufnr()
  var right = state.GetRightBufnr()

  # Clear guard flags before closing so the fold guard doesn't interfere
  if left != -1 && bufexists(left)
    setbufvar(left, 'gh_review_diff', false)
  endif
  if right != -1 && bufexists(right)
    setbufvar(right, 'gh_review_diff', false)
  endif

  # Close the left diff window
  if left != -1 && bufexists(left)
    var winid = bufwinid(left)
    if winid != -1
      win_gotoid(winid)
      close
    endif
  endif

  # Replace right diff buffer with an empty buffer
  if right != -1 && bufexists(right)
    var winid = bufwinid(right)
    if winid != -1
      win_gotoid(winid)
      diffoff
      enew
    endif
  endif

  state.SetLeftBufnr(-1)
  state.SetRightBufnr(-1)
  state.SetDiffPath('')

  # Return focus to the files list
  var files_bufnr = state.GetFilesBufnr()
  var files_winid = files_bufnr != -1 ? bufwinid(files_bufnr) : -1
  if files_winid != -1
    win_gotoid(files_winid)
  endif
enddef
