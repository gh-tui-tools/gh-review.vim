vim9script

# Process boundary: the only place that spawns external commands for
# the async API layer (api.vim).  Kept deliberately minimal so tests can
# shadow this module via 'runtimepath' (see test/mock/) and exercise
# everything above it unchanged.

# Run a command asynchronously.  Callback receives (stdout, stderr,
# exit_status) and is deferred to the main loop.
export def Run(cmd: list<string>, Callback: func(string, string, number))
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
