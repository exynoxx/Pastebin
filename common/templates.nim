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

template getOr404*[T](opt: Option[T]; ctx, msg: untyped): T =
    let optVal = opt
    if optVal.isNone:
        ctx.respondError(404, msg)
        return
    optVal.get
