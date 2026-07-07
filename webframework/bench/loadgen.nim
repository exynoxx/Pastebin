## Dependency-free HTTP/1.1 load generator for benchserver.
##
## It reproduces the framework's real connection lifecycle: connect -> send one request ->
## drain the response -> close, over and over. The server always answers `Connection: close`,
## so there is no keep-alive to exploit — a fresh TCP connection per request IS the workload,
## and any load tool would end up doing exactly this. Built on std/net (the same primitive the
## server uses) so it never becomes the bottleneck a mismatched keep-alive tool would.
##
## Env knobs:
##   HOST     (default 127.0.0.1)
##   PORT     (default 8080)
##   TARGET   (default /plaintext)   request path
##   CONNS    (default 50)           concurrent connections = client threads
##   DURATION (default 10)           seconds of steady-state load

import std/[net, os, strutils, times, monotimes]

type Sample = object
    count: int          ## completed request/response round-trips
    errors: int         ## connect/send/recv failures
    sumLatUs: int64     ## summed per-request latency (connect->close), microseconds
    maxLatUs: int64

var
    gHost: string
    gPort: Port
    gRequest: string
    gDeadline: MonoTime
    gSamples: seq[Sample]   ## one slot per worker (unique index => no contention)

proc worker(id: int) {.thread.} =
    {.cast(gcsafe).}:   # reads immutable globals set before any worker starts
        var s: Sample
        let host = gHost
        let port = gPort
        let req = gRequest
        var buf = newString(64 * 1024)
        while getMonoTime() < gDeadline:
            let t0 = getMonoTime()
            try:
                let sock = newSocket(buffered = false)
                try:
                    sock.connect(host, port)
                    sock.send(req)
                    while sock.recv(addr buf[0], buf.len) > 0: discard  # drain until close
                finally:
                    sock.close()
                let us = inMicroseconds(getMonoTime() - t0)
                inc s.count
                s.sumLatUs += us
                if us > s.maxLatUs: s.maxLatUs = us
            except CatchableError:
                inc s.errors
        gSamples[id] = s

when isMainModule:
    gHost = getEnv("HOST", "127.0.0.1")
    gPort = Port(parseInt(getEnv("PORT", "8080")))
    let target = getEnv("TARGET", "/plaintext")
    let conns = parseInt(getEnv("CONNS", "50"))
    let duration = parseInt(getEnv("DURATION", "10"))

    gRequest = "GET " & target & " HTTP/1.1\r\nHost: " & gHost & "\r\n\r\n"
    gSamples = newSeq[Sample](conns)
    gDeadline = getMonoTime() + initDuration(seconds = duration)

    var threads = newSeq[Thread[int]](conns)
    for i in 0 ..< conns:
        createThread(threads[i], worker, i)
    joinThreads(threads)

    var total, errors: int
    var sumLat, maxLat: int64
    for s in gSamples:
        total += s.count
        errors += s.errors
        sumLat += s.sumLatUs
        if s.maxLatUs > maxLat: maxLat = s.maxLatUs

    let rps = total.float / duration.float
    let avgUs = if total > 0: sumLat.float / total.float else: 0.0
    # One machine-parsable line so run.sh can tabulate; keys are stable.
    echo "RESULT conns=", conns, " dur=", duration,
         " target=", target,
         " requests=", total, " errors=", errors,
         " rps=", formatFloat(rps, ffDecimal, 0),
         " avg_us=", formatFloat(avgUs, ffDecimal, 1),
         " max_us=", maxLat
