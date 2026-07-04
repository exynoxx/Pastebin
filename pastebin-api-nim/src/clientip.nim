## Real client IP resolution, mirroring pastebin-api/services/ClientIp.cs.
##
## Verified against the live deployment via /api/debug/ip: public traffic arrives
## Tailscale Funnel -> nginx -> API. Funnel sets X-Forwarded-For to the real public client and
## DISCARDS any client-supplied XFF (so the leftmost entry can't be spoofed through the public
## path); nginx then appends its own $remote_addr (the docker-bridge gateway). So the real client
## is the FIRST X-Forwarded-For entry, e.g. "93.165.245.57, 172.18.0.1".
##
## X-Real-IP is nginx's $remote_addr — the constant gateway address for every public visitor — so
## preferring it (as this once did) collapses ALL public users into one rate-limit/quota bucket.
## Precedence: first X-Forwarded-For -> X-Real-IP -> connection remote -> "unknown".

import std/[strutils, sequtils]
import webframework/httpserver

proc resolveClientIp*(req: Request): string =
    [
        req.header("X-Forwarded-For").split(',', 1)[0].strip(),
        req.header("X-Real-IP").strip(),
        req.remoteAddress,
        "unknown",
    ]
    .filterIt(it.len > 0)[0]
