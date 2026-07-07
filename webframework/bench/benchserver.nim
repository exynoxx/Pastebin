## Benchmark server: exercises pure framework overhead — parse -> route -> dispatch -> respond —
## with zero app logic, DB, or blob I/O. Any time or memory the profiler attributes here is the
## framework's own cost, which is the whole point of the isolation.
##
## Env knobs so run.sh can sweep without recompiling:
##   PORT     (default 8080)
##   THREADS  (default 4)   worker threads accepting on the shared socket

import std/[os, strutils]
import ../server

type BenchState = object   ## no app dependencies — this is the framework alone

proc handlePlaintext(ctx: Ctx[BenchState]) =
    ctx.respond(200, "OK", contentType = "text/plain; charset=utf-8")

proc handleJson(ctx: Ctx[BenchState]) =
    ctx.respond(200, """{"message":"ok"}""")

proc registerRoutes(): RouteTable[BenchState] =
    result.get("/plaintext", handlePlaintext)
    result.get("/json", handleJson)

when isMainModule:
    var cfg = defaultConfig()
    cfg.port = parseInt(getEnv("PORT", "8080"))
    cfg.numThreads = parseInt(getEnv("THREADS", "4"))
    cfg.networkLog = false
    serve(registerRoutes(), BenchState(), cfg)
