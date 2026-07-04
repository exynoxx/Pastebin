## GET /api/debug/ip — echo the resolved client IP + the forwarding header chain (diagnostic).

import std/json
import ../context
import ../../clientip

proc handleDebugIp*(ctx: Ctx) =
    ctx.req.respond(200, $(%*{
        "resolvedClientIp": resolveClientIp(ctx.req),
        "xForwardedFor": ctx.req.header("X-Forwarded-For"),
        "xRealIp": ctx.req.header("X-Real-IP"),
        "xForwardedProto": ctx.req.header("X-Forwarded-Proto"),
        "connectionRemoteIp": ctx.req.remoteAddress,
        "host": ctx.req.header("Host"),
    }))
