## Guard-clause helper: collapses the `if <cond>: return` early-return pattern into a
## single call. Must be a template (not a proc) so the `return` exits the *enclosing*
## routine — same rationale as fetchOr404/withIpState in the webframework. Use the colon
## form at call sites: `returnif: <cond>`.

template returnif*(cond: bool) =
    ## Return from the enclosing routine when `cond` holds.
    if cond: return
