vim9script

# Tests for autoload/gh_review/graphql.vim

var test_dir = expand('<sfile>:p:h')
execute 'source ' .. test_dir .. '/helpers.vim'

import autoload 'gh_review/graphql.vim'

# All constant names to test
var constants = {
  QUERY_PR_DETAILS: graphql.QUERY_PR_DETAILS,
  QUERY_REVIEW_THREADS: graphql.QUERY_REVIEW_THREADS,
  MUTATION_START_REVIEW: graphql.MUTATION_START_REVIEW,
  MUTATION_SUBMIT_REVIEW: graphql.MUTATION_SUBMIT_REVIEW,
  MUTATION_ADD_REVIEW_THREAD: graphql.MUTATION_ADD_REVIEW_THREAD,
  MUTATION_ADD_REVIEW_COMMENT: graphql.MUTATION_ADD_REVIEW_COMMENT,
  MUTATION_RESOLVE_THREAD: graphql.MUTATION_RESOLVE_THREAD,
  MUTATION_UNRESOLVE_THREAD: graphql.MUTATION_UNRESOLVE_THREAD,
  MUTATION_DELETE_REVIEW: graphql.MUTATION_DELETE_REVIEW,
  MUTATION_CREATE_AND_SUBMIT_REVIEW: graphql.MUTATION_CREATE_AND_SUBMIT_REVIEW,
}

g:RunTest('All 10 GraphQL constants are strings', () => {
  for [name, val] in items(constants)
    assert_equal(v:t_string, type(val), name .. ' should be a string')
  endfor
})

g:RunTest('All GraphQL constants are non-empty', () => {
  for [name, val] in items(constants)
    assert_equal(true, len(val) > 0, name .. ' should be non-empty')
  endfor
})

g:RunTest('QUERY_PR_DETAILS contains expected fragments', () => {
  var q = graphql.QUERY_PR_DETAILS
  assert_match('pullRequest', q)
  assert_match('reviewThreads', q)
  assert_match('files', q)
  assert_match('reviews', q)
  assert_match('baseRefName', q)
  assert_match('headRefOid', q)
})

g:RunTest('QUERY_REVIEW_THREADS contains reviewThreads', () => {
  assert_match('reviewThreads', graphql.QUERY_REVIEW_THREADS)
  assert_match('comments', graphql.QUERY_REVIEW_THREADS)
  assert_match('pullRequestReview', graphql.QUERY_REVIEW_THREADS)
})

g:RunTest('Mutations contain mutation keyword', () => {
  assert_match('^mutation', graphql.MUTATION_START_REVIEW)
  assert_match('^mutation', graphql.MUTATION_SUBMIT_REVIEW)
  assert_match('^mutation', graphql.MUTATION_ADD_REVIEW_THREAD)
  assert_match('^mutation', graphql.MUTATION_ADD_REVIEW_COMMENT)
  assert_match('^mutation', graphql.MUTATION_RESOLVE_THREAD)
  assert_match('^mutation', graphql.MUTATION_UNRESOLVE_THREAD)
  assert_match('^mutation', graphql.MUTATION_CREATE_AND_SUBMIT_REVIEW)
})

g:RunTest('Queries contain query keyword', () => {
  assert_match('^query', graphql.QUERY_PR_DETAILS)
  assert_match('^query', graphql.QUERY_REVIEW_THREADS)
})

g:RunTest('MUTATION_ADD_REVIEW_THREAD has line/side/path params', () => {
  var m = graphql.MUTATION_ADD_REVIEW_THREAD
  assert_match('\$path', m)
  assert_match('\$line', m)
  assert_match('\$side', m)
  assert_match('\$body', m)
})

g:RunTest('MUTATION_CREATE_AND_SUBMIT_REVIEW has event and pullRequestId params', () => {
  var m = graphql.MUTATION_CREATE_AND_SUBMIT_REVIEW
  assert_match('\$pullRequestId', m)
  assert_match('\$event', m)
  assert_match('PullRequestReviewEvent', m)
})

g:RunTest('MUTATION_SUBMIT_REVIEW has event param', () => {
  assert_match('\$event', graphql.MUTATION_SUBMIT_REVIEW)
  assert_match('PullRequestReviewEvent', graphql.MUTATION_SUBMIT_REVIEW)
})

# --- Write results and exit ---

g:WriteResults('/tmp/gh_review_test_graphql.txt')
