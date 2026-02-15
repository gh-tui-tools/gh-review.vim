vim9script

# Top-level orchestration for gh-review.vim.

import autoload 'gh_review/api.vim'
import autoload 'gh_review/graphql.vim'
import autoload 'gh_review/state.vim'
import autoload 'gh_review/files.vim'
import autoload 'gh_review/diff.vim'
import autoload 'gh_review/thread.vim'

# Open a PR for review.  If no number given, detect from current branch.
export def Open(pr_number_str: string = '')
  # Check that gh is available
  if !executable('gh')
    echoerr '[gh-review] `gh` CLI not found. Install it from https://cli.github.com'
    return
  endif

  var pr_number: number
  var url_owner = ''
  var url_name = ''
  if empty(pr_number_str)
    echo 'Detecting PR for current branch...'
    var detected = trim(system('gh pr view --json number -q .number 2>/dev/null'))
    if v:shell_error != 0 || empty(detected)
      echoerr '[gh-review] No PR found for the current branch'
      return
    endif
    pr_number = str2nr(detected)
  else
    # Accept a full GitHub PR URL or a plain number
    var url_match = matchlist(pr_number_str, 'github\.com/\([^/]\+\)/\([^/]\+\)/pull/\(\d\+\)')
    if !empty(url_match)
      url_owner = url_match[1]
      url_name = url_match[2]
      pr_number = str2nr(url_match[3])
    else
      pr_number = str2nr(pr_number_str)
    endif
  endif

  if pr_number <= 0
    echoerr '[gh-review] Invalid PR number or URL: ' .. pr_number_str
    return
  endif

  # Determine repo and whether checkout is possible.
  # If URL specifies a repo, use it; otherwise detect from git remote.
  var should_checkout = false
  if !empty(url_owner)
    state.SetRepoInfo(url_owner, url_name)
    should_checkout = IsLocalRepo(url_owner, url_name)
  else
    if !state.GetRepoInfo()
      return
    endif
    should_checkout = true
  endif

  state.SetLocalCheckout(should_checkout)

  echo printf('Loading PR #%d...', pr_number)

  var owner = state.GetOwner()
  var name = state.GetName()

  var vars: dict<any> = {
    owner: owner,
    name: name,
    number: pr_number,
  }
  api.GraphQL(graphql.QUERY_PR_DETAILS, vars, (result) => {
    var pr = get(get(get(result, 'data', {}), 'repository', {}), 'pullRequest', {})
    if empty(pr)
      echoerr '[gh-review] Failed to load PR details'
      return
    endif

    state.SetPR(result)

    var thread_nodes = get(get(pr, 'reviewThreads', {}), 'nodes', [])
    state.SetThreads(thread_nodes)

    var LoadUI = () => {
      FetchMergeBase(() => {
        files.Open()
        echo printf('PR #%d loaded: %s', state.GetPRNumber(), state.GetPRTitle())
      })
    }

    if should_checkout
      var local_branch = state.GetHeadRef()
      var current_branch = trim(system('git rev-parse --abbrev-ref HEAD 2>/dev/null'))
      if current_branch ==# local_branch
        LoadUI()
        return
      endif

      var choice = confirm(printf('Check out branch %s?', local_branch), "&Yes\n&No", 1)
      if choice != 1
        should_checkout = false
        state.SetLocalCheckout(false)
        LoadUI()
        return
      endif

      # Check out the PR branch locally via GitHub pull refs (works for forks
      # without needing a fork remote).
      var fetch_ref = printf('pull/%d/head', pr_number)
      api.RunCmdAsync(['git', 'fetch', 'origin', fetch_ref], (fo, fe, fetch_exit) => {
        if fetch_exit != 0
          echohl WarningMsg
          echomsg '[gh-review] Could not fetch PR branch: ' .. trim(fe)
          echohl None
          state.SetLocalCheckout(false)
          LoadUI()
        else
          api.RunCmdAsync(['git', 'checkout', '-B', local_branch, 'FETCH_HEAD'], (co, ce, co_exit) => {
            if co_exit == 0
              SetupPushTracking(local_branch)
              echomsg printf('[gh-review] Checked out branch %s', local_branch)
            else
              echohl WarningMsg
              echomsg '[gh-review] Could not check out PR branch: ' .. trim(ce)
              echohl None
              state.SetLocalCheckout(false)
            endif
            LoadUI()
          })
        endif
      })
    else
      LoadUI()
    endif
  })
enddef

def IsLocalRepo(owner: string, name: string): bool
  var remote = trim(system('git remote get-url origin 2>/dev/null'))
  if v:shell_error != 0
    return false
  endif
  return remote =~# '\V' .. escape(owner .. '/' .. name, '\')
enddef

def SetupPushTracking(local_branch: string)
  var head_owner = state.GetHeadRepoOwner()
  var head_name = state.GetHeadRepoName()
  var head_branch = state.GetHeadRef()
  var repo_owner = state.GetOwner()

  var remote: string
  if head_owner ==# repo_owner
    remote = 'origin'
  else
    # Fork PR — ensure a remote exists for the fork.
    remote = head_owner
    var remote_url = trim(system('git remote get-url '
      .. shellescape(remote) .. ' 2>/dev/null'))
    if v:shell_error != 0
      # Add remote, matching origin’s protocol (SSH vs HTTPS).
      var origin_url = trim(system('git remote get-url origin'))
      var fork_url: string
      if origin_url =~# '^git@'
        fork_url = printf('git@github.com:%s/%s.git', head_owner, head_name)
      else
        fork_url = printf('https://github.com/%s/%s.git', head_owner, head_name)
      endif
      system(printf('git remote add %s %s',
        shellescape(remote), shellescape(fork_url)))
      if v:shell_error != 0
        echohl WarningMsg
        echomsg printf('[gh-review] Could not add remote for fork %s', remote)
        echohl None
        return
      endif
    endif
  endif

  system(printf('git config %s %s',
    shellescape('branch.' .. local_branch .. '.remote'), shellescape(remote)))
  if v:shell_error != 0
    echohl WarningMsg
    echomsg '[gh-review] Could not configure push tracking'
    echohl None
    return
  endif
  system(printf('git config %s %s',
    shellescape('branch.' .. local_branch .. '.merge'),
    shellescape('refs/heads/' .. head_branch)))
  if v:shell_error != 0
    echohl WarningMsg
    echomsg '[gh-review] Could not configure push tracking'
    echohl None
  endif
enddef

def FetchMergeBase(Callback: func())
  var owner = state.GetOwner()
  var name = state.GetName()
  var base = state.GetBaseRef()
  var head = state.GetHeadRef()

  # Try local git merge-base first
  var merge_base = trim(system(printf('git merge-base %s %s 2>/dev/null',
    shellescape('origin/' .. base), shellescape('origin/' .. head))))

  if v:shell_error == 0 && !empty(merge_base)
    state.SetMergeBaseOid(merge_base)
    Callback()
    return
  endif

  # Fall back to REST compare endpoint
  var endpoint = printf('/repos/%s/%s/compare/%s...%s', owner, name, base, head)
  api.RunAsync(['api', endpoint], (stdout, stderr) => {
    if empty(stderr)
      try
        var parsed = json_decode(stdout)
        var commit = get(parsed, 'merge_base_commit', {})
        if !empty(commit)
          state.SetMergeBaseOid(get(commit, 'sha', ''))
        endif
      catch
        # JSON parse failed; fall through
      endtry
    endif
    # Use base OID as fallback if merge base is still empty
    if empty(state.GetMergeBaseOid())
      echohl WarningMsg
      echomsg '[gh-review] Could not determine merge base; diff may be inaccurate'
      echohl None
      state.SetMergeBaseOid(state.GetBaseOid())
    endif
    Callback()
  })
enddef

# Toggle the files list.
export def ToggleFiles()
  files.Toggle()
enddef

# Start a pending review.
export def StartReview()
  if state.IsReviewActive()
    echo 'A pending review is already active'
    return
  endif

  if empty(state.GetPRId())
    echoerr '[gh-review] No PR loaded. Use :GHReview {number|url} first.'
    return
  endif

  echo 'Starting review...'
  var start_vars: dict<any> = {pullRequestId: state.GetPRId()}
  api.GraphQL(graphql.MUTATION_START_REVIEW, start_vars, (result) => {
    var review = get(get(get(result, 'data', {}), 'addPullRequestReview', {}), 'pullRequestReview', {})
    if !empty(review)
      state.SetPendingReviewId(review.id)
      echo 'Review started. Comments will be held as pending until you submit.'
    else
      echoerr '[gh-review] Failed to start review'
    endif
  })
enddef

# Submit a review.  If a pending review is active, submit it; otherwise
# create and submit a review in one step.
export def SubmitReview()
  if empty(state.GetPRId())
    echoerr '[gh-review] No PR loaded. Use :GHReview {number|url} first.'
    return
  endif

  popup_menu(['Comment', 'Approve', 'Request changes'], {
    title: ' Submit review as ',
    border: [],
    padding: [0, 1, 0, 1],
    callback: (_, choice) => {
      if choice < 1
        echo 'Cancelled'
        return
      endif

      var events = ['COMMENT', 'APPROVE', 'REQUEST_CHANGES']
      var event = events[choice - 1]

      var DoSubmit = (body: string) => {
        echo 'Submitting review...'

        if state.IsReviewActive()
          var vars: dict<any> = {
            reviewId: state.GetPendingReviewId(),
            event: event,
          }
          if !empty(body)
            vars.body = body
          endif

          api.GraphQL(graphql.MUTATION_SUBMIT_REVIEW, vars, (result) => {
            var review = get(get(get(result, 'data', {}), 'submitPullRequestReview', {}), 'pullRequestReview', {})
            if !empty(review)
              state.SetPendingReviewId('')
              echo 'Review submitted as ' .. event
              RefreshThreads()
            else
              echoerr '[gh-review] Failed to submit review'
            endif
          })
        else
          var vars: dict<any> = {
            pullRequestId: state.GetPRId(),
            event: event,
          }
          if !empty(body)
            vars.body = body
          endif

          api.GraphQL(graphql.MUTATION_CREATE_AND_SUBMIT_REVIEW, vars, (result) => {
            var review = get(get(get(result, 'data', {}), 'addPullRequestReview', {}), 'pullRequestReview', {})
            if !empty(review)
              echo 'Review submitted as ' .. event
              RefreshThreads()
            else
              echoerr '[gh-review] Failed to submit review'
            endif
          })
        endif
      }

      if choice == 1 || choice == 3
        inputsave()
        var body = input('Review body (optional): ')
        inputrestore()
        DoSubmit(body)
      else
        DoSubmit('')
      endif
    },
  })
enddef

# Discard the pending review (delete it and all its pending comments).
export def DiscardReview()
  if !state.IsReviewActive()
    echoerr '[gh-review] No pending review to discard.'
    return
  endif

  var choice = confirm('Discard pending review and all its comments?', "&Yes\n&No", 2)
  if choice != 1
    echo 'Cancelled'
    return
  endif

  echo 'Discarding review...'
  var vars: dict<any> = {pullRequestReviewId: state.GetPendingReviewId()}
  api.GraphQL(graphql.MUTATION_DELETE_REVIEW, vars, (result) => {
    var review = get(get(get(result, 'data', {}), 'deletePullRequestReview', {}), 'pullRequestReview', {})
    if !empty(review)
      state.SetPendingReviewId('')
      RefreshThreads()
      echo 'Pending review discarded'
    else
      echoerr '[gh-review] Failed to discard review'
    endif
  })
enddef

# Refresh threads from GitHub and update signs/files list.
export def RefreshThreads()
  if empty(state.GetPRId())
    return
  endif

  var refresh_vars: dict<any> = {
    owner: state.GetOwner(),
    name: state.GetName(),
    number: state.GetPRNumber(),
  }
  api.GraphQL(graphql.QUERY_REVIEW_THREADS, refresh_vars, (result) => {
    var pr = get(get(get(result, 'data', {}), 'repository', {}), 'pullRequest', {})
    var thread_nodes = get(get(pr, 'reviewThreads', {}), 'nodes', [])
    state.SetThreads(thread_nodes)
    diff.RefreshSigns()
    files.Rerender()
    echo 'Threads refreshed'
  })
enddef

# Statusline component: returns "" when no review is active, or a summary.
export def Statusline(): string
  if empty(state.GetPRId())
    return ''
  endif
  var parts: list<string> = []
  add(parts, printf('PR #%d', state.GetPRNumber()))
  if state.IsReviewActive()
    add(parts, 'reviewing')
  endif
  var thread_count = len(state.GetThreads())
  if thread_count > 0
    add(parts, printf('%d %s', thread_count, thread_count == 1 ? 'thread' : 'threads'))
  endif
  return join(parts, ' · ')
enddef

# Close all review buffers and reset state.
export def Close()
  thread.CloseThreadBuffer()
  diff.CloseDiff()

  # Close files list
  files.Close()

  # Wipe any remaining gh-review buffers
  for bufinfo in getbufinfo()
    if bufinfo.name =~# '^gh-review://'
      execute 'silent! bwipeout!' bufinfo.bufnr
    endif
  endfor

  state.Reset()
  echo 'Review closed'
enddef
