vim9script

# Async wrapper around the `gh` CLI.

# Run an arbitrary command asynchronously.
# Callback receives (stdout, stderr, exit_status).
export def RunCmdAsync(cmd: list<string>, Callback: func(string, string, number))
  var stdout_lines: list<string> = []
  var stderr_lines: list<string> = []

  var job = job_start(cmd, {
    out_mode: 'raw',
    err_mode: 'raw',
    out_cb: (ch, msg) => {
      add(stdout_lines, msg)
    },
    err_cb: (ch, msg) => {
      add(stderr_lines, msg)
    },
    exit_cb: (job_handle, exit_status) => {
      var out = join(stdout_lines, '')
      var err = join(stderr_lines, '')
      # Defer callback to the main loop so it runs outside the job handler
      timer_start(0, (_) => Callback(out, err, exit_status))
    },
  })
enddef

# Run a gh command asynchronously.  Callback receives (stdout, stderr).
export def RunAsync(cmd: list<string>, Callback: func(string, string))
  RunCmdAsync(['gh'] + cmd, (stdout, stderr, _) => Callback(stdout, stderr))
enddef

# Run a GraphQL query/mutation.  Callback receives the parsed dict.
export def GraphQL(query: string, variables: dict<any>, Callback: func(dict<any>))
  var cmd = ['api', 'graphql']
  for [key, val] in items(variables)
    # -f passes as string, -F passes as JSON (needed for Int, Boolean, etc.)
    var flag = type(val) == v:t_string ? '-f' : '-F'
    cmd += [flag, key .. '=' .. (type(val) == v:t_string ? val : string(val))]
  endfor
  cmd += ['-f', 'query=' .. query]

  RunAsync(cmd, (stdout, stderr) => {
    if !empty(stderr)
      echoerr '[gh-review] GraphQL error: ' .. stderr
      return
    endif
    var parsed: dict<any>
    try
      parsed = json_decode(stdout)
    catch
      echoerr '[gh-review] Failed to parse GraphQL response'
      return
    endtry
    if has_key(parsed, 'errors') && !empty(parsed.errors)
      echoerr '[gh-review] GraphQL error: ' .. string(parsed.errors[0].message)
      return
    endif
    Callback(parsed)
  })
enddef
