vim9script

# Test double for autoload/gh_review/job.vim.
#
# A test prepends test/mock to 'runtimepath' before any autoload import,
# so `import autoload 'gh_review/job.vim'` (in api.vim and in the test)
# resolves here instead of to the real module.  Must keep the same
# signature as the real Run().

# Lets a test assert that the shadow is active (and not the real module).
export const IS_MOCK = true

# Receives the full command and returns [stdout, stderr, exit_status].
var Responder: func(list<string>): list<any> = null_function

export def SetResponder(Fn: func(list<string>): list<any>)
  Responder = Fn
enddef

export def ClearResponder()
  Responder = null_function
enddef

# Hands the command to the responder and invokes Callback synchronously.
# Never spawns a process: without a responder this is an error.
export def Run(cmd: list<string>, Callback: func(string, string, number))
  if Responder == null_function
    throw 'mock job.vim: no responder set for ' .. string(cmd)
  endif
  var [out, err, status] = Responder(cmd)
  Callback(out, err, status)
enddef
