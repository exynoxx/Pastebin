template swallowException*(body: untyped) =
    try:
        body
    except CatchableError:
        discard
