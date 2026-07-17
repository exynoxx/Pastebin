## Guard-clause helpers: collapse the `if <cond>: return [value]` early-return pattern into
## one call. Like fetchOr404/withIpState in the webframework, these must be templates (not
## procs) so the `return` exits the *enclosing* routine, not a nested one.

template returnif*(cond: bool) =
    ## Return (no value) from the enclosing routine when `cond` holds.
    if cond: return

template returnif*(cond: bool, value: untyped) =
    ## Return `value` from the enclosing routine when `cond` holds. `value` is `untyped` so it
    ## stays lazy (evaluated only when returning) and accepts any return type the caller uses —
    ## bool, enum, tuple, `Option.none(...)`, etc.
    if cond: return value
