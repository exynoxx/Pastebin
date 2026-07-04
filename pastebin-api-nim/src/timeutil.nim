## Timestamp helpers.
##
## The .NET backend stores created_at/uploaded_at via DateTime.ToUniversalTime().ToString("o"),
## e.g. "2026-07-04T12:34:56.7890000Z" (ISO-8601 round-trip, 7 fractional digits, trailing Z),
## and sorts the recent list lexicographically on that text column. We treat these values as
## opaque ISO strings everywhere on the read path, and generate the SAME format for new rows so
## the shared DB stays readable by the .NET backend on rollback and lexicographic ORDER BY holds.

import std/times

proc nowIso*(): string =
    ## Current UTC time as .NET "o" format: yyyy-MM-ddTHH:mm:ss.fffffffZ (7 fractional digits).
    let t = getTime()
    let dt = t.utc
    # nanoseconds within the second -> 100ns "ticks" (7 digits), matching .NET's precision.
    let ticks = dt.nanosecond div 100
    result = dt.format("yyyy-MM-dd'T'HH:mm:ss")
    result.add '.'
    var frac = $ticks
    while frac.len < 7: frac = "0" & frac
    result.add frac
    result.add 'Z'

proc isoToUniversal*(iso: string): string =
    ## Reformat a stored ISO timestamp to .NET's "u" (universal sortable) format used inside
    ## create-paste-from-file content: "2026-07-04 12:34:56Z" (space instead of T, no fraction).
    ## Tolerant of both fractional and non-fractional inputs.
    if iso.len < 19:
        return iso
    var s = iso[0 .. 18]          # yyyy-MM-ddTHH:mm:ss
    if s.len > 10 and s[10] == 'T':
        s[10] = ' '
    s.add 'Z'
    result = s
