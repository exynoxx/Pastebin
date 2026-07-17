## General control-flow templates shared across the whole project (framework + app).
##
## Each is a `template` rather than a `proc` on purpose: the `return`/early-exit must leave the
## *enclosing* routine, which only a template can do. This is the innermost, dependency-free leaf of
## the onion — it imports nothing but the stdlib, so both `webframework/` and `pastebin-api/` can
## depend inward on it.

import std/options

template swallowException*(body: untyped) =
    ## Run `body`, discarding any `CatchableError` it raises. For genuinely fire-and-forget cleanup
    ## and best-effort I/O where a failure must never propagate (peer disconnects, temp-file removal).
    try:
        body
    except CatchableError:
        discard

template returnif*(cond: bool) =
    ## Guard-clause helper: return from the enclosing routine when `cond` holds. Use the colon form at
    ## call sites: `returnif: <cond>`.
    if cond: return

template importuse*(m: untyped) =
    ## Import module `m` for qualified-only access: `importuse blobstore` expands to
    ## `from blobstore import nil`, so callers must write `blobstore.foo(...)` and can't shadow the
    ## origin with a bare `foo(...)`. Named `importuse` (not `use`) because `use` collides with
    ## `routetable.use`, and `using` is a reserved keyword. Relies on `--path:"src"` (nim.cfg) so a
    ## bare module name resolves from nested endpoint files.
    from m import nil

template fetchOr404*(ctx, opt, msg: untyped): untyped =
    ## Yield the value inside an `Option`, or respond 404 with `msg` and return from the handler.
    ## `isNone`/`get` also resolve at the call site (every handler using this imports std/options).
    let optVal = opt
    if optVal.isNone:
        ctx.respondError(404, msg)
        return
    optVal.get
