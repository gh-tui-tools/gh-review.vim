vim9script

# Fixture data for gh-review.vim tests.
# Returns dicts matching the GraphQL response shape.

# Full PR data matching the structure of a QUERY_PR_DETAILS response.
# Contains 3 files (ADDED, MODIFIED, DELETED), 4 threads across 2 files,
# including one with line: null, one resolved, one with pending review comment,
# and a pending review in reviews.nodes.
def g:MockPRData(): dict<any>
  return {
    data: {
      repository: {
        pullRequest: {
          id: 'PR_abc123',
          number: 42,
          title: 'Add feature X',
          state: 'OPEN',
          baseRefName: 'main',
          baseRefOid: 'aaa111',
          headRefName: 'feature-x',
          headRefOid: 'bbb222',
          headRepository: {
            owner: {login: 'testowner'},
            name: 'testrepo',
          },
          files: {
            nodes: [
              {path: 'src/new_file.ts', additions: 50, deletions: 0, changeType: 'ADDED'},
              {path: 'src/existing.ts', additions: 10, deletions: 5, changeType: 'MODIFIED'},
              {path: 'src/old_file.ts', additions: 0, deletions: 30, changeType: 'DELETED'},
            ]
          },
          reviewThreads: {
            nodes: [
              {
                id: 'thread_1',
                isResolved: false,
                isOutdated: false,
                line: 10,
                originalLine: 10,
                startLine: v:null,
                originalStartLine: v:null,
                diffSide: 'RIGHT',
                path: 'src/new_file.ts',
                comments: {nodes: [
                  {id: 'comment_1', body: 'Looks good', author: {login: 'alice'}, createdAt: '2025-01-15T10:30:00Z', pullRequestReview: {id: 'rev_1', state: 'COMMENTED'}},
                ]},
              },
              {
                id: 'thread_2',
                isResolved: true,
                isOutdated: false,
                line: 25,
                originalLine: 25,
                startLine: 20,
                originalStartLine: 20,
                diffSide: 'RIGHT',
                path: 'src/new_file.ts',
                comments: {nodes: [
                  {id: 'comment_2', body: 'Fix this', author: {login: 'bob'}, createdAt: '2025-01-15T11:00:00Z', pullRequestReview: {id: 'rev_2', state: 'COMMENTED'}},
                  {id: 'comment_3', body: 'Done', author: {login: 'alice'}, createdAt: '2025-01-15T12:00:00Z', pullRequestReview: {id: 'rev_2', state: 'COMMENTED'}},
                ]},
              },
              {
                id: 'thread_3',
                isResolved: false,
                isOutdated: false,
                line: v:null,
                originalLine: 8,
                startLine: v:null,
                originalStartLine: v:null,
                diffSide: 'RIGHT',
                path: 'src/existing.ts',
                comments: {nodes: [
                  {id: 'comment_4', body: 'General comment', author: {login: 'bob'}, createdAt: '2025-01-15T13:00:00Z', pullRequestReview: {id: 'rev_3', state: 'COMMENTED'}},
                ]},
              },
              {
                id: 'thread_4',
                isResolved: false,
                isOutdated: false,
                line: 5,
                originalLine: 5,
                startLine: v:null,
                originalStartLine: v:null,
                diffSide: 'LEFT',
                path: 'src/existing.ts',
                comments: {nodes: [
                  {id: 'comment_5', body: 'Pending note', author: {login: 'alice'}, createdAt: '2025-01-16T09:00:00Z', pullRequestReview: {id: 'pending_rev_1', state: 'PENDING'}},
                ]},
              },
            ]
          },
          reviews: {
            nodes: [
              {id: 'pending_rev_1', state: 'PENDING'},
            ]
          },
        }
      }
    }
  }
enddef

# Fork PR data: headRepository owner differs from the repo owner.
def g:MockForkPRData(): dict<any>
  var data = g:MockPRData()
  data.data.repository.pullRequest.headRepository = {
    owner: {login: 'forkuser'},
    name: 'testrepo',
  }
  data.data.repository.pullRequest.headRefName = 'fork-feature'
  return data
enddef


# PR data where headRepository is null (deleted fork).
def g:MockDeletedForkPRData(): dict<any>
  var data = g:MockPRData()
  data.data.repository.pullRequest.headRepository = v:null
  return data
enddef

# Just the thread nodes list (for SetThreads).
def g:MockThreadNodes(): list<any>
  var data = g:MockPRData()
  return data.data.repository.pullRequest.reviewThreads.nodes
enddef

# PR data with all five change types (ADDED, MODIFIED, DELETED, RENAMED, COPIED).
def g:MockAllChangeTypesPRData(): dict<any>
  var data = g:MockPRData()
  data.data.repository.pullRequest.files.nodes = [
    {path: 'src/new_file.ts', additions: 50, deletions: 0, changeType: 'ADDED'},
    {path: 'src/existing.ts', additions: 10, deletions: 5, changeType: 'MODIFIED'},
    {path: 'src/old_file.ts', additions: 0, deletions: 30, changeType: 'DELETED'},
    {path: 'src/moved.ts', additions: 2, deletions: 1, changeType: 'RENAMED'},
    {path: 'src/cloned.ts', additions: 0, deletions: 0, changeType: 'COPIED'},
  ]
  return data
enddef
