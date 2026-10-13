vim9script

# Authoritative pending-review resolution.
#
# Every action that targets or depends on a pending review calls Resolve()
# first and uses the ID it yields for that single invocation only. The ID
# is never cached: the review may be started, submitted or discarded
# elsewhere (web UI, another session, implicitly by GitHub) at any time.
# Only a display hint (state.LastKnownReviewActive()) is kept, refreshed
# as a side effect.

import autoload 'gh_review/state.vim'
import autoload 'gh_review/api.vim'
import autoload 'gh_review/graphql.vim'

# Fetch the viewer's current pending review for the loaded PR.  Callback
# receives its ID, or '' if there is none.  On API failure the error is
# reported and Callback is not invoked.
export def Resolve(Callback: func(string))
  var vars: dict<any> = {
    owner: state.GetOwner(),
    name: state.GetName(),
    number: state.GetPRNumber(),
  }
  api.GraphQL(graphql.QUERY_PENDING_REVIEW, vars, (result) => {
    var pr = get(get(get(result, 'data', {}), 'repository', {}), 'pullRequest', {})
    var review_id = state.PendingReviewIdFrom(pr)
    state.SetLastKnownReviewActive(!empty(review_id))
    Callback(review_id)
  })
enddef
