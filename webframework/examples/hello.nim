## Minimal demo: one route, injected app state, one `run` call.

import ../server

type AppState = object
    greeting: string

proc handleHello(ctx: Ctx[AppState]) =
    ctx.respond(200, ctx.cfg.greeting, contentType = "text/plain; charset=utf-8")

proc registerRoutes(): RouteTable[AppState] =
    result.get("/hello", handleHello)

when isMainModule:
    let state = AppState(greeting: "hello world")
    run(registerRoutes(), state)
