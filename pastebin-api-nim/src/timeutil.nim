## Timestamp helpers.
##
## Timestamps are stored and transported as Unix epoch milliseconds (UTC). The frontend
## renders them directly with `new Date(ms)`, and SQLite sorts them numerically.

import std/[times, strutils]

proc nowMillis*(): int64 =
    ## Current UTC time as Unix epoch milliseconds.
    let t = getTime()
    t.toUnix() * 1000 + (t.nanosecond div 1_000_000)

proc formatMillisUtc*(ms: int64): string =
    ## Human-readable UTC, e.g. "2026-07-04 12:34:56Z" — used inside file-attachment paste bodies.
    fromUnix(ms div 1000).utc.format("yyyy-MM-dd HH:mm:ss") & "Z"

proc isoToMillis*(iso: string): int64 =
    ## Parse a legacy .NET "o" timestamp ("2026-07-04T12:34:56.7890000Z") to epoch millis.
    ## Used only by the one-shot startup migration of pre-epoch DBs. Tolerant/lenient:
    ## returns 0 on anything it can't read.
    if iso.len < 19: return 0
    var secs: int64
    try:
        secs = parse(iso[0 .. 18], "yyyy-MM-dd'T'HH:mm:ss", utc()).toTime().toUnix()
    except CatchableError:
        return 0
    result = secs * 1000
    # Append up to 3 fractional digits (milliseconds), zero-padded.
    if iso.len > 20 and iso[19] == '.':
        var frac = ""
        var i = 20
        while i < iso.len and iso[i] in {'0' .. '9'} and frac.len < 3:
            frac.add iso[i]
            inc i
        while frac.len < 3: frac.add '0'
        try: result += parseInt(frac)
        except ValueError: discard
