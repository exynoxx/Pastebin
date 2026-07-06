## Timestamp helpers.
##
## Timestamps are stored and transported as Unix epoch milliseconds (UTC). The frontend
## renders them directly with `new Date(ms)`, and SQLite sorts them numerically.

import std/times

## Current UTC time as Unix epoch milliseconds.
proc nowMillis*(): int64 = (getTime() - fromUnix(0)).inMilliseconds

## Human-readable UTC, e.g. "2026-07-04 12:34:56Z" — used inside file-attachment paste bodies.
proc formatMillisUtc*(ms: int64): string = fromUnix(ms div 1000).utc.format("yyyy-MM-dd HH:mm:ss") & "Z"
