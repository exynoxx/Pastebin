## App request context — specialises the framework's generic context for this service. Endpoint
## handlers `import ../context` and get, from one import: `Ctx` (bound to this app's config),
## `Request`, `respond`/`respondFile`, `AppConfig`, and `errorJson`/`respondError`. JSON response
## builders are no longer central: each lives in its own vertical slice (e.g. endpoints/files/json,
## or inline in the handler). Rate-limit rejection helpers live with their logic in ratelimit.nim.

import ../webframework/httpserver
import ../webframework/context as fctx
import ../config

export httpserver, config
export fctx.errorJson, fctx.respondError

type
    Ctx* = fctx.Ctx[AppConfig]
        ## The framework's generic context bound to this app's config bundle.
    EndpointHandler* = fctx.Handler[AppConfig]
        ## Uniform handler signature the app's route table dispatches to.
