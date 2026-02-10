vim9script

# Tests for URL parsing and argument handling in Open().
# These test the matchlist pattern used to extract PR numbers from URLs,
# exercised directly since Open() itself requires network access.

var test_dir = expand('<sfile>:p:h')
execute 'source ' .. test_dir .. '/helpers.vim'

# Helper: given a string argument, return a dict with owner, name, number
# using the same parsing logic as Open().
def ParsePRURL(arg: string): dict<any>
  var url_match = matchlist(arg, 'github\.com/\([^/]\+\)/\([^/]\+\)/pull/\(\d\+\)')
  if !empty(url_match)
    return {owner: url_match[1], name: url_match[2], number: str2nr(url_match[3])}
  else
    return {owner: '', name: '', number: str2nr(arg)}
  endif
enddef

# Helper: given a string argument (number or URL), return the parsed PR number
# using the same logic as Open().
def ParsePRNumber(arg: string): number
  return ParsePRURL(arg).number
enddef

# --- Tests ---

g:RunTest('Parse plain number', () => {
  assert_equal(123, ParsePRNumber('123'))
  assert_equal(1, ParsePRNumber('1'))
  assert_equal(99999, ParsePRNumber('99999'))
})

g:RunTest('Parse GitHub PR URL', () => {
  assert_equal(42, ParsePRNumber('https://github.com/owner/repo/pull/42'))
  assert_equal(39880, ParsePRNumber('https://github.com/mdn/content/pull/39880'))
})

g:RunTest('Parse URL with trailing path segments', () => {
  assert_equal(100, ParsePRNumber('https://github.com/owner/repo/pull/100/files'))
  assert_equal(100, ParsePRNumber('https://github.com/owner/repo/pull/100/commits'))
})

g:RunTest('Parse URL with query string or fragment', () => {
  assert_equal(55, ParsePRNumber('https://github.com/owner/repo/pull/55?diff=split'))
  assert_equal(55, ParsePRNumber('https://github.com/owner/repo/pull/55#discussion'))
})

g:RunTest('Invalid input returns zero', () => {
  assert_equal(0, ParsePRNumber('not-a-number'))
  assert_equal(0, ParsePRNumber(''))
  assert_equal(0, ParsePRNumber('https://github.com/owner/repo'))
})

g:RunTest('Parse URL extracts owner and repo', () => {
  var result = ParsePRURL('https://github.com/owner/repo/pull/42')
  assert_equal('owner', result.owner)
  assert_equal('repo', result.name)
  assert_equal(42, result.number)
})

g:RunTest('Parse URL with org/repo names', () => {
  var result = ParsePRURL('https://github.com/mdn/content/pull/39880')
  assert_equal('mdn', result.owner)
  assert_equal('content', result.name)
  assert_equal(39880, result.number)
})

g:RunTest('Plain number has empty owner and name', () => {
  var result = ParsePRURL('123')
  assert_equal('', result.owner)
  assert_equal('', result.name)
  assert_equal(123, result.number)
})

g:RunTest('Parse URL with files tab and diff anchor', () => {
  var result = ParsePRURL('https://github.com/mdn/content/pull/42276/files#diff-fcec8db9553a615a137defcf2624ae9937e6ebab9835a408d9f2f50a4e734864')
  assert_equal('mdn', result.owner)
  assert_equal('content', result.name)
  assert_equal(42276, result.number)
})

g:RunTest('Parse URL with commits tab and SHA', () => {
  var result = ParsePRURL('https://github.com/mdn/content/pull/42276/commits/d66a80fd8b932fc573bd57f1c76ad07538e74e0e')
  assert_equal('mdn', result.owner)
  assert_equal('content', result.name)
  assert_equal(42276, result.number)
})

# --- Write results and exit ---

g:WriteResults('/tmp/gh_review_test_open.txt')
