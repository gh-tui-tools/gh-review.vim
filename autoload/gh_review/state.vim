vim9script

# PR state management.  Holds all data for the currently active review.

# PR metadata
var pr_id: string = ''
var pr_number: number = 0
var pr_title: string = ''
var pr_state: string = ''
var base_ref: string = ''
var base_oid: string = ''
var head_ref: string = ''
var head_oid: string = ''
var head_repo_owner: string = ''
var head_repo_name: string = ''
var merge_base_oid: string = ''

# Repo info
var repo_owner: string = ''
var repo_name: string = ''

# Changed files: list of dicts with path, additions, deletions, changeType
var changed_files: list<dict<any>> = []

# Review threads indexed by id
var threads: dict<dict<any>> = {}

# Pending review id (empty string if no active pending review)
var pending_review_id: string = ''

# Buffer and window IDs
var files_bufnr: number = -1
var left_bufnr: number = -1
var right_bufnr: number = -1
var thread_bufnr: number = -1
var thread_winid: number = -1

# Current diff file path
var diff_path: string = ''
var is_local_checkout: bool = false

# ------- Getters / Setters -------

export def GetPRId(): string
  return pr_id
enddef

export def GetPRNumber(): number
  return pr_number
enddef

export def GetPRTitle(): string
  return pr_title
enddef

export def GetPRState(): string
  return pr_state
enddef

export def GetBaseRef(): string
  return base_ref
enddef

export def GetBaseOid(): string
  return base_oid
enddef

export def GetHeadRef(): string
  return head_ref
enddef

export def GetHeadOid(): string
  return head_oid
enddef

export def GetHeadRepoOwner(): string
  return head_repo_owner
enddef

export def GetHeadRepoName(): string
  return head_repo_name
enddef

export def GetMergeBaseOid(): string
  return merge_base_oid
enddef

export def SetMergeBaseOid(oid: string)
  merge_base_oid = oid
enddef

export def GetOwner(): string
  return repo_owner
enddef

export def GetName(): string
  return repo_name
enddef

export def GetChangedFiles(): list<dict<any>>
  return changed_files
enddef

export def GetPendingReviewId(): string
  return pending_review_id
enddef

export def SetPendingReviewId(id: string)
  pending_review_id = id
enddef

export def IsReviewActive(): bool
  return !empty(pending_review_id)
enddef

# Buffer/window accessors

export def GetFilesBufnr(): number
  return files_bufnr
enddef

export def SetFilesBufnr(nr: number)
  files_bufnr = nr
enddef

export def GetLeftBufnr(): number
  return left_bufnr
enddef

export def SetLeftBufnr(nr: number)
  left_bufnr = nr
enddef

export def GetRightBufnr(): number
  return right_bufnr
enddef

export def SetRightBufnr(nr: number)
  right_bufnr = nr
enddef

export def GetThreadBufnr(): number
  return thread_bufnr
enddef

export def SetThreadBufnr(nr: number)
  thread_bufnr = nr
enddef

export def GetThreadWinid(): number
  return thread_winid
enddef

export def SetThreadWinid(id: number)
  thread_winid = id
enddef

export def GetDiffPath(): string
  return diff_path
enddef

export def SetDiffPath(path: string)
  diff_path = path
enddef

export def IsLocalCheckout(): bool
  return is_local_checkout
enddef

export def SetLocalCheckout(val: bool)
  is_local_checkout = val
enddef

# ------- PR data loading -------

export def SetPR(data: dict<any>)
  var pr = data.data.repository.pullRequest
  pr_id = pr.id
  pr_number = pr.number
  pr_title = pr.title
  pr_state = pr.state
  base_ref = pr.baseRefName
  base_oid = pr.baseRefOid
  head_ref = pr.headRefName
  head_oid = pr.headRefOid
  var head_repo = get(pr, 'headRepository', v:null)
  if head_repo != v:null
    head_repo_owner = head_repo.owner.login
    head_repo_name = head_repo.name
  endif

  changed_files = pr.files.nodes

  # Pick up an existing pending review if one exists
  if has_key(pr, 'reviews') && !empty(pr.reviews.nodes)
    for review in pr.reviews.nodes
      if review.state ==# 'PENDING'
        pending_review_id = review.id
        break
      endif
    endfor
  endif
enddef

export def SetThreads(thread_nodes: list<any>)
  threads = {}
  for t in thread_nodes
    threads[t.id] = t
  endfor
enddef

export def GetThreads(): dict<dict<any>>
  return threads
enddef

export def GetThread(id: string): dict<any>
  return get(threads, id, {})
enddef

export def SetThread(id: string, data: dict<any>)
  threads[id] = data
enddef

# Return threads for a given file path.
export def GetThreadsForFile(path: string): list<dict<any>>
  var result: list<dict<any>> = []
  for t in values(threads)
    if get(t, 'path', '') ==# path
      add(result, t)
    endif
  endfor
  return result
enddef

# ------- Repo detection -------

export def GetRepoInfo(): bool
  var remote = trim(system('git remote get-url origin 2>/dev/null'))
  if v:shell_error != 0
    echoerr '[gh-review] Not in a git repository or no origin remote'
    return false
  endif

  # Parse SSH format: git@github.com:owner/name.git
  var ssh_match = matchlist(remote, 'git@github\.com:\([^/]\+\)/\([^/]\+\)')
  if !empty(ssh_match)
    repo_owner = ssh_match[1]
    repo_name = substitute(ssh_match[2], '\.git$', '', '')
    return true
  endif

  # Parse HTTPS format: https://github.com/owner/name.git
  var https_match = matchlist(remote, 'github\.com/\([^/]\+\)/\([^/]\+\)')
  if !empty(https_match)
    repo_owner = https_match[1]
    repo_name = substitute(https_match[2], '\.git$', '', '')
    return true
  endif

  echoerr '[gh-review] Could not parse GitHub remote URL: ' .. remote
  return false
enddef

export def SetRepoInfo(owner: string, name: string)
  repo_owner = owner
  repo_name = name
enddef

# Return unique sorted author logins from all thread comments.
export def GetParticipants(): list<string>
  var seen: dict<bool> = {}
  for t in values(threads)
    var comments = get(get(t, 'comments', {}), 'nodes', [])
    for c in comments
      var login = get(get(c, 'author', {}), 'login', '')
      if !empty(login)
        seen[login] = true
      endif
    endfor
  endfor
  return sort(keys(seen))
enddef

# ------- Reset -------

export def Reset()
  pr_id = ''
  pr_number = 0
  pr_title = ''
  pr_state = ''
  base_ref = ''
  base_oid = ''
  head_ref = ''
  head_oid = ''
  head_repo_owner = ''
  head_repo_name = ''
  merge_base_oid = ''
  repo_owner = ''
  repo_name = ''
  changed_files = []
  threads = {}
  pending_review_id = ''
  files_bufnr = -1
  left_bufnr = -1
  right_bufnr = -1
  thread_bufnr = -1
  thread_winid = -1
  diff_path = ''
  is_local_checkout = false
enddef
