import std/options

template swallowException*(body: untyped) =
    try:
        body
    except CatchableError:
        discard

template returnif*(cond: bool) =
    if cond: return

template referencing*(m: untyped) =
    from m import nil

template fetchOr404*(ctx, opt, msg: untyped): untyped =
    ## Yield the value inside an `Option`, or respond 404 with `msg` and return from the handler.
    ## `isNone`/`get` also resolve at the call site (every handler using this imports std/options).
    let optVal = opt
    if optVal.isNone:
        ctx.respondError(404, msg)
        return
    optVal.get
