## General-purpose macros/templates shared across the webframework slice.
##
## App-agnostic building blocks used by more than one webserver module. Feature-specific
## templates (e.g. the handler-level `fetchOr404` / `parseJsonBodyOr400` in context.nim) stay
## with the module they serve — only genuinely reusable ones belong here.

template swallowException*(body: untyped) =
    ## Run `body`, swallowing any `CatchableError`. For best-effort work where a failure is
    ## expected and irrelevant: closing a socket, deleting a temp file, or writing to a peer
    ## that may already have disconnected.
    try:
        body
    except CatchableError:
        discard
