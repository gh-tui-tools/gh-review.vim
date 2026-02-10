vim9script

# Shared test helpers for gh-review.vim test suite.
# Source this at the top of every test file.

# Add plugin root to rtp so import autoload works
var test_dir = expand('<sfile>:p:h')
var plugin_root = fnamemodify(test_dir, ':h')
&rtp = plugin_root .. ',' .. &rtp

# Source the plugin file so signs/highlights/commands are defined
execute 'source ' .. plugin_root .. '/plugin/gh_review.vim'

# --- Test infrastructure ---

g:test_results = []

def g:RunTest(name: string, Fn: func())
  v:errors = []
  try
    Fn()
  catch
    add(v:errors, 'Exception: ' .. v:exception)
  endtry
  if empty(v:errors)
    add(g:test_results, 'PASS: ' .. name)
  else
    for err in v:errors
      add(g:test_results, 'FAIL: ' .. name .. ' - ' .. err)
    endfor
  endif
enddef

def g:WriteResults(filename: string)
  writefile(g:test_results, filename)
  qall!
enddef
