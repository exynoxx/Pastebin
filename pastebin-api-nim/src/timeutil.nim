## Timestamp helpers.
##
## Timestamps are stored and transported as Unix epoch milliseconds (UTC). The frontend
## renders them directly with `new Date(ms)`, and SQLite sorts them numerically.

import std/times

proc nowMillis*(): int64 =
    ## Current UTC time as Unix epoch milliseconds.
    let t = getTime()
    t.toUnix() * 1000 + (t.nanosecond div 1_000_000)

proc formatMillisUtc*(ms: int64): string =
    ## Human-readable UTC, e.g. "2026-07-04 12:34:56Z" — used inside file-attachment paste bodies.
    fromUnix(ms div 1000).utc.format("yyyy-MM-dd HH:mm:ss") & "Z"
