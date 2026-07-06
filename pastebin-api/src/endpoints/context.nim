import webframework/httpserver
import webframework/context as fctx
import ../config

export httpserver, config
export fctx.errorJson, fctx.respondError, fctx.fetchOr404, fctx.parseJsonBodyOr400

type
    Ctx* = fctx.Ctx[AppConfig]
        ## The framework's generic context bound to this app's config bundle.
    EndpointHandler* = fctx.Handler[AppConfig]
        ## Uniform handler signature the app's route table dispatches to.
