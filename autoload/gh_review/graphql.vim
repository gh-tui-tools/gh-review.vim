vim9script

# GraphQL queries and mutations for PR review.
# Heredocs produce list<string>; we join them into strings for the API.

# Fetch PR metadata, changed files, and review threads with comments.
var query_pr_details_lines =<< trim GRAPHQL
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        id
        number
        title
        state
        baseRefName
        baseRefOid
        headRefName
        headRefOid
        headRepository {
          owner { login }
          name
        }
        files(first: 100) {
          nodes {
            path
            additions
            deletions
            changeType
          }
        }
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            isOutdated
            line
            originalLine
            startLine
            originalStartLine
            diffSide
            path
            comments(first: 50) {
              nodes {
                id
                body
                author {
                  login
                }
                createdAt
                pullRequestReview {
                  id
                  state
                }
              }
            }
          }
        }
        reviews(first: 10, states: PENDING) {
          nodes {
            id
            state
          }
        }
      }
    }
  }
GRAPHQL
export const QUERY_PR_DETAILS = join(query_pr_details_lines, "\n")

# Refresh review threads only.
var query_review_threads_lines =<< trim GRAPHQL
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            isOutdated
            line
            originalLine
            startLine
            originalStartLine
            diffSide
            path
            comments(first: 50) {
              nodes {
                id
                body
                author {
                  login
                }
                createdAt
                pullRequestReview {
                  id
                  state
                }
              }
            }
          }
        }
      }
    }
  }
GRAPHQL
export const QUERY_REVIEW_THREADS = join(query_review_threads_lines, "\n")

# Start a new pending review.
var mutation_start_review_lines =<< trim GRAPHQL
  mutation($pullRequestId: ID!) {
    addPullRequestReview(input: {pullRequestId: $pullRequestId}) {
      pullRequestReview {
        id
        state
      }
    }
  }
GRAPHQL
export const MUTATION_START_REVIEW = join(mutation_start_review_lines, "\n")

# Create and immediately submit a review (no prior pending review needed).
var mutation_create_and_submit_review_lines =<< trim GRAPHQL
  mutation($pullRequestId: ID!, $event: PullRequestReviewEvent!, $body: String) {
    addPullRequestReview(input: {pullRequestId: $pullRequestId, event: $event, body: $body}) {
      pullRequestReview {
        id
        state
      }
    }
  }
GRAPHQL
export const MUTATION_CREATE_AND_SUBMIT_REVIEW = join(mutation_create_and_submit_review_lines, "\n")

# Submit a pending review with an event and optional body.
var mutation_submit_review_lines =<< trim GRAPHQL
  mutation($reviewId: ID!, $event: PullRequestReviewEvent!, $body: String) {
    submitPullRequestReview(input: {pullRequestReviewId: $reviewId, event: $event, body: $body}) {
      pullRequestReview {
        id
        state
      }
    }
  }
GRAPHQL
export const MUTATION_SUBMIT_REVIEW = join(mutation_submit_review_lines, "\n")

# Create a new review thread (comment on a specific line).
var mutation_add_review_thread_lines =<< trim GRAPHQL
  mutation($pullRequestId: ID!, $body: String!, $path: String!, $line: Int!, $side: DiffSide!, $startLine: Int, $startSide: DiffSide, $pullRequestReviewId: ID) {
    addPullRequestReviewThread(input: {
      pullRequestId: $pullRequestId,
      body: $body,
      path: $path,
      line: $line,
      side: $side,
      startLine: $startLine,
      startSide: $startSide,
      pullRequestReviewId: $pullRequestReviewId
    }) {
      thread {
        id
        isResolved
        line
        startLine
        diffSide
        path
        comments(first: 50) {
          nodes {
            id
            body
            author {
              login
            }
            createdAt
          }
        }
      }
    }
  }
GRAPHQL
export const MUTATION_ADD_REVIEW_THREAD = join(mutation_add_review_thread_lines, "\n")

# Reply to an existing review thread.
var mutation_add_review_comment_lines =<< trim GRAPHQL
  mutation($pullRequestReviewId: ID!, $threadId: ID!, $body: String!) {
    addPullRequestReviewComment(input: {
      pullRequestReviewId: $pullRequestReviewId,
      inReplyTo: $threadId,
      body: $body
    }) {
      comment {
        id
        body
        author {
          login
        }
        createdAt
      }
    }
  }
GRAPHQL
export const MUTATION_ADD_REVIEW_COMMENT = join(mutation_add_review_comment_lines, "\n")

# Note: standalone thread replies (no pending review) use the REST API
# POST /repos/{owner}/{repo}/pulls/{number}/comments/{comment_id}/replies
# See thread.vim for the implementation.

# Resolve a thread.
var mutation_resolve_thread_lines =<< trim GRAPHQL
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread {
        id
        isResolved
      }
    }
  }
GRAPHQL
export const MUTATION_RESOLVE_THREAD = join(mutation_resolve_thread_lines, "\n")

# Unresolve a thread.
var mutation_unresolve_thread_lines =<< trim GRAPHQL
  mutation($threadId: ID!) {
    unresolveReviewThread(input: {threadId: $threadId}) {
      thread {
        id
        isResolved
      }
    }
  }
GRAPHQL
export const MUTATION_UNRESOLVE_THREAD = join(mutation_unresolve_thread_lines, "\n")

# Delete a pending review (discard all pending comments).
var mutation_delete_review_lines =<< trim GRAPHQL
  mutation($pullRequestReviewId: ID!) {
    deletePullRequestReview(input: {pullRequestReviewId: $pullRequestReviewId}) {
      pullRequestReview {
        id
        state
      }
    }
  }
GRAPHQL
export const MUTATION_DELETE_REVIEW = join(mutation_delete_review_lines, "\n")
