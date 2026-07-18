## Minimal HTTP/1.1 server for the Pastebin backend.
##
## Deliberately small and purpose-built: it sits behind nginx (which terminates TLS, buffers
## and normalises client traffic), so it only ever faces well-formed HTTP/1.1 from one trusted
## upstream. That lets us skip the hard parts of a general server and instead nail the two
## things this app actually needs and that off-the-shelf Nim servers don't give for free:
##
##   1. Request bodies above a threshold are STREAMED to a temp file (`bodyFilePath`) instead of
##      being buffered in RAM — so a ~100 MB upload never blows the 250 MB container cap.
##   2. `respondFile` streams a file (optionally a single Range) from disk in bounded chunks with
##      200/206 + Accept-Ranges/Content-Range — so downloads don't allocate the whole file.
##
## Concurrency model: a fixed pool of worker threads each block on accept() on the shared
## listening socket (safe on Linux) and handle ONE request per connection, then close
## (`Connection: close`). No keep-alive / pipelining keeps the state machine trivial and correct;
## nginx re-uses upstream connections cheaply and the workload is tiny.

import std/[net, os, strutils, uri, json]
from std/posix import Timeval, Time, Suseconds, Socklen, setsockopt,
    SOL_SOCKET, SO_RCVTIMEO, SO_SNDTIMEO
import common/templates
import tmpfile

type
    Request* = ref object
        httpMethod*: string             ## "GET", "POST", ...
        path*: string                   ## request path, query stripped
        rawQuery*: string               ## raw query string (after '?')
        headers*: seq[(string, string)] ## in received order; use header() for lookup
        body*: string                   ## in-memory body (empty when spilled to disk)
        bodyFilePath*: string           ## temp file with the body when spilled; "" otherwise
        remoteAddress*: string
        socket: Socket
        responded: bool
        statusCode*: int                ## status actually sent (0 until a response is written)

    RequestHandler* = proc(req: Request) {.nimcall, gcsafe.}

const
    RecvChunk = 64 * 1024
    SendChunk = 1 shl 20              # 1 MB streaming buffer for respondFile

var
    gHandler: RequestHandler
    gBodySpillThreshold: int
    gMaxBodyBytes: int64
    gRequestTimeoutMs: int

# Reused across every request a worker serves (each worker handles one connection at a time, so
# there's no aliasing): a threadvar buffer costs one allocation per thread for the process lifetime
# instead of one per request. gRecvBuf reads request bytes; gSendBuf streams file downloads.
var
    gRecvBuf {.threadvar.}: string
    gSendBuf {.threadvar.}: string

func addBytes(dst: var string, src: string, n: int) =
    ## Append src[0 ..< n] to dst without allocating the `src[0 ..< n]` slice temporary.
    if n <= 0: return
    let old = dst.len
    dst.setLen(old + n)
    copyMem(addr dst[old], unsafeAddr src[0], n)

func reason(code: int): string =
    ## Reason phrase for the status codes this app emits. A case (not a global Table) keeps the
    ## proc GC-safe so it can run on the worker threads.
    case code
    of 200: "OK"
    of 206: "Partial Content"
    of 400: "Bad Request"
    of 404: "Not Found"
    of 408: "Request Timeout"
    of 413: "Payload Too Large"
    of 416: "Range Not Satisfiable"
    of 429: "Too Many Requests"
    of 500: "Internal Server Error"
    of 503: "Service Unavailable"
    else: "OK"

# ---- request helpers -------------------------------------------------------

func header*(req: Request, name: string): string =
    ## Case-insensitive header lookup; "" if absent (standard HTTP semantics).
    for (k, v) in req.headers:
        if cmpIgnoreCase(k, name) == 0:
            return v
    ""

proc bodyString*(req: Request): string =
    ## Full request body in memory, reading the spill file if the body was spilled to disk.
    ## For endpoints that must parse the whole body (e.g. JSON). Bounded by the route's limits.
    if req.bodyFilePath.len > 0: readFile(req.bodyFilePath) else: req.body

proc bodyLen*(req: Request): int64 =
    ## Byte length of the full body WITHOUT reading it into memory — the spill file's size when
    ## spilled, else the in-memory body length. Lets handlers reject an oversize body before the
    ## whole thing is materialised/parsed (e.g. createPaste's pre-parse size guard).
    if req.bodyFilePath.len > 0: getFileSize(req.bodyFilePath) else: req.body.len.int64

proc bodyFile*(req: Request): string =
    ## Path to a file holding the full body, materialising one from the in-memory body when the
    ## body wasn't spilled. Sets req.bodyFilePath so the server's cleanup removes it. Used for
    ## streaming multipart parsing.
    if req.bodyFilePath.len == 0:
        let p = uniqueTempPath("pb-body")
        writeFile(p, req.body)
        req.bodyFilePath = p
        req.body = ""
    req.bodyFilePath

func queryParam*(req: Request, name: string): string =
    ## Value of a query parameter, or "" if absent. decodeQuery handles '+'/%xx.
    if req.rawQuery.len == 0: return ""
    for (k, v) in decodeQuery(req.rawQuery):
        if k == name:
            return v
    ""

# ---- response helpers ------------------------------------------------------

proc sendAll(sock: Socket, data: string) =
    if data.len > 0:
        sock.send(data)

proc sendAll(sock: Socket, buf: pointer, size: int) =
    ## Loop until all `size` bytes at `buf` are sent — the raw `send` may short-write.
    var sent = 0
    while sent < size:
        let n = sock.send(cast[pointer](cast[uint](buf) + sent.uint), size - sent)
        if n <= 0: break
        sent += n

func buildHead(code: int, headers: seq[(string, string)]): string =
    result = "HTTP/1.1 " & $code & " " & reason(code) & "\r\n"
    for (k, v) in headers:
        result.add k & ": " & v & "\r\n"
    result.add "Connection: close\r\n\r\n"

proc writeStatusAndHeaders(req: Request, code: int,
                           headers: seq[(string, string)]) =
    ## Send the status line + headers only. Used by the streaming paths (respondFile), where the
    ## body can't be coalesced into one buffer.
    req.statusCode = code
    req.socket.sendAll(buildHead(code, headers))

proc respond*(req: Request, statusCode: int, body: string,
              contentType = "application/json; charset=utf-8",
              extraHeaders: openArray[(string, string)] = []) =
    ## Buffered response (JSON / small text). Sets Content-Type + Content-Length.
    if req.responded: return
    req.responded = true
    req.statusCode = statusCode
    var hs: seq[(string, string)]
    hs.add ("Content-Type", contentType)
    hs.add ("Content-Length", $body.len)
    for h in extraHeaders: hs.add h
    swallowException: # peer may disconnect before/while receiving the response
        # One buffer, one send(): headers followed by the (small) body. respond is only for
        # small/JSON payloads — large data goes through respondFile — so the concat is cheap and
        # saves a syscall per request versus sending head and body separately.
        var msg = buildHead(statusCode, hs)
        msg.add body
        req.socket.sendAll(msg)

func parseSingleRange(rangeHeader: string, size: int64):
        tuple[ok, satisfiable: bool, first, last: int64] =
    ## Parses "bytes=START-END" / "bytes=START-" / "bytes=-SUFFIX" for a single range.
    ## ok=false => no/!valid range header (serve full 200). ok=true+satisfiable=false => 416.
    result = (false, false, 0'i64, 0'i64)
    const prefix = "bytes="
    if not rangeHeader.toLowerAscii().startsWith(prefix): return
    let spec = rangeHeader[prefix.len .. ^1].strip()
    if spec.len == 0 or ',' in spec: return   # multi-range unsupported -> treat as no range
    let dash = spec.find('-')
    if dash < 0: return
    let startStr = spec[0 ..< dash].strip()
    let endStr = spec[dash + 1 .. ^1].strip()
    var first, last: int64
    try:
        if startStr.len == 0:
            # suffix range: last N bytes
            if endStr.len == 0: return
            let suffix = parseBiggestInt(endStr).int64
            if suffix <= 0: return (true, false, 0'i64, 0'i64)
            first = max(0'i64, size - suffix)
            last = size - 1
        else:
            first = parseBiggestInt(startStr).int64
            last = if endStr.len > 0: parseBiggestInt(endStr).int64 else: size - 1
    except ValueError:
        return
    if first > last or first < 0: return
    if first >= size: return (true, false, 0'i64, 0'i64)   # unsatisfiable -> 416
    if last >= size: last = size - 1
    result = (true, true, first, last)

proc streamFileRange(sock: Socket, f: File, first, count: int64) =
    ## Stream `count` bytes starting at `first` from `f` to the socket in bounded chunks.
    f.setFilePos(first)
    var remaining = count
    if gSendBuf.len < SendChunk: gSendBuf.setLen(SendChunk)
    while remaining > 0:
        let want = int(min(remaining, SendChunk.int64))
        let n = f.readBuffer(addr gSendBuf[0], want)
        if n <= 0: break
        # Send the first n bytes straight from the buffer — no slice copy for a partial last chunk.
        sock.sendAll(addr gSendBuf[0], n)
        remaining -= n

proc respondFile*(req: Request, path, contentType: string,
                  rangeHeader = "", contentDisposition = "", noSniff = false) =
    ## Streams a file from disk with optional single-range support. 404 if unreadable.
    if req.responded: return
    req.responded = true

    var f: File
    if not open(f, path, fmRead):
        req.statusCode = 404
        let body = $(%*{"error": "Not found"})
        swallowException:
            var msg = buildHead(404,
                @[("Content-Type", "application/json; charset=utf-8"),
                    ("Content-Length", $body.len)])
            msg.add body
            req.socket.sendAll(msg)
        return
    defer: f.close()

    let size = f.getFileSize()
    var hs: seq[(string, string)]
    hs.add ("Content-Type", contentType)
    hs.add ("Accept-Ranges", "bytes")
    if contentDisposition.len > 0: hs.add ("Content-Disposition", contentDisposition)
    if noSniff: hs.add ("X-Content-Type-Options", "nosniff")

    swallowException: # peer may disconnect mid-stream
        let r = parseSingleRange(rangeHeader, size)
        if r.ok and not r.satisfiable:
            hs.add ("Content-Range", "bytes */" & $size)
            hs.add ("Content-Length", "0")
            writeStatusAndHeaders(req, 416, hs)
            return
        if r.ok and r.satisfiable:
            let count = r.last - r.first + 1
            hs.add ("Content-Range", "bytes " & $r.first & "-" & $r.last & "/" & $size)
            hs.add ("Content-Length", $count)
            writeStatusAndHeaders(req, 206, hs)
            streamFileRange(req.socket, f, r.first, count)
        else:
            hs.add ("Content-Length", $size)
            writeStatusAndHeaders(req, 200, hs)
            streamFileRange(req.socket, f, 0, size)

# ---- request reading -------------------------------------------------------

func parseRequestLineAndHeaders(req: Request, headerText: string): bool =
    ## Parse the request line + header block by index, allocating only the strings actually kept
    ## (method, path, query, header keys/values). Avoids split()'s per-line seq and strip()'s
    ## per-header temporaries. Returns false on a malformed request line.
    let hlen = headerText.len
    var lineEnd = headerText.find("\r\n")
    if lineEnd < 0: lineEnd = hlen

    # request line: METHOD SP URI (SP VERSION)?
    let sp1 = headerText.find(' ')
    if sp1 <= 0 or sp1 >= lineEnd: return false
    var uriEnd = headerText.find(' ', sp1 + 1)
    if uriEnd < 0 or uriEnd > lineEnd: uriEnd = lineEnd
    if uriEnd <= sp1 + 1: return false
    req.httpMethod = headerText[0 ..< sp1]
    let uri = headerText[sp1 + 1 ..< uriEnd]
    let q = uri.find('?')
    if q >= 0:
        req.path = uri[0 ..< q].decodeUrl()
        req.rawQuery = uri[q + 1 .. ^1]
    else:
        req.path = uri.decodeUrl()

    # header lines: "key: value", trimmed to the stored ranges without a strip() temporary
    var pos = lineEnd + 2
    while pos < hlen:
        var eol = headerText.find("\r\n", pos)
        if eol < 0: eol = hlen
        let colon = headerText.find(':', pos)
        if colon >= pos and colon < eol:
            var ks = pos
            var ke = colon
            while ks < ke and headerText[ks] in {' ', '\t'}: inc ks
            while ke > ks and headerText[ke - 1] in {' ', '\t'}: dec ke
            var vs = colon + 1
            var ve = eol
            while vs < ve and headerText[vs] in {' ', '\t'}: inc vs
            while ve > vs and headerText[ve - 1] in {' ', '\t'}: dec ve
            if ke > ks:
                req.headers.add (headerText[ks ..< ke], headerText[vs ..< ve])
        pos = eol + 2
    true

proc setSocketTimeouts(sock: Socket, timeoutMs: int) =
    ## Arm SO_RCVTIMEO/SO_SNDTIMEO on the accepted connection: any recv()/send() that makes no
    ## progress for `timeoutMs` returns <= 0 (the loops below treat that as end-of-connection), so a
    ## stalled/slowloris client frees its worker instead of pinning it forever. This is the server's
    ## ONLY request timeout — each worker is one of just `numThreads`, so a few stuck sockets would
    ## otherwise starve every other client. nginx has its own timeouts; this is the backstop for the
    ## worker pool (and the sole guard on the direct-to-:8080 path).
    if timeoutMs <= 0: return
    var tv = Timeval(tv_sec: Time(timeoutMs div 1000),
                     tv_usec: Suseconds((timeoutMs mod 1000) * 1000))
    let fd = sock.getFd()
    discard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, addr tv, Socklen(sizeof(tv)))
    discard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, addr tv, Socklen(sizeof(tv)))

proc handleConnection(sock: Socket, remote: string) =
    ## Reads exactly one request, dispatches it, cleans up. Never raises.
    var req = Request(socket: sock, remoteAddress: remote)
    var bodyTemp = ""
    setSocketTimeouts(sock, gRequestTimeoutMs)
    try:
        # --- read the header block (until CRLF CRLF), keeping any body bytes read past it ---
        if gRecvBuf.len < RecvChunk: gRecvBuf.setLen(RecvChunk)
        var pending = ""
        var headerEnd = -1
        var readTimedOut = false
        while headerEnd < 0:
            let n = sock.recv(addr gRecvBuf[0], RecvChunk)
            if n <= 0:
                readTimedOut = n < 0   # <0 = recv timeout/error; 0 = peer closed cleanly
                break
            pending.addBytes(gRecvBuf, n)
            headerEnd = pending.find("\r\n\r\n")
            if pending.len > 64 * 1024 and headerEnd < 0:
                req.respond(400, $(%*{"error": "Header too large"}))
                return
        if headerEnd < 0:
            # Nothing (or only a partial header block) arrived. A timeout means a slow/stalled
            # client — tell it so; a clean close needs no reply.
            if readTimedOut: req.respond(408, $(%*{"error": "Request timeout"}))
            return

        let headerText = pending[0 ..< headerEnd]
        var leftover = pending[headerEnd + 4 .. ^1]  # first body bytes already received

        # --- parse request line + headers ---
        if not parseRequestLineAndHeaders(req, headerText):
            req.respond(400, $(%*{"error": "Bad request"}))
            return

        # --- body ---
        var contentLength: int64 = 0
        let clStr = req.header("Content-Length")
        if clStr.len > 0:
            try: contentLength = parseBiggestInt(clStr).int64
            except ValueError: contentLength = 0
        if contentLength > gMaxBodyBytes:
            req.respond(413, $(%*{"error": "Payload too large"}))
            return

        if contentLength > 0:
            if contentLength > gBodySpillThreshold.int64:
                # Spill to a temp file, streaming from the socket in bounded chunks.
                bodyTemp = uniqueTempPath("pb-body")
                req.bodyFilePath = bodyTemp
                let outF = open(bodyTemp, fmWrite)
                var received: int64 = 0
                if leftover.len > 0:
                    discard outF.writeBuffer(addr leftover[0], leftover.len)
                    received = leftover.len.int64
                while received < contentLength:
                    let want = int(min((contentLength - received), RecvChunk.int64))
                    let n = sock.recv(addr gRecvBuf[0], want)
                    if n <= 0: break
                    discard outF.writeBuffer(addr gRecvBuf[0], n)
                    received += n
                outF.close()
                if received < contentLength:
                    # Body stalled/closed before the promised Content-Length — don't dispatch a
                    # truncated request; 408 (a stalled slow client is the usual cause behind nginx).
                    req.respond(408, $(%*{"error": "Request timeout"}))
                    return
            else:
                # Small body: read into memory.
                req.body = leftover
                while req.body.len.int64 < contentLength:
                    let want = int(min((contentLength - req.body.len.int64), RecvChunk.int64))
                    let n = sock.recv(addr gRecvBuf[0], want)
                    if n <= 0: break
                    req.body.addBytes(gRecvBuf, n)
                if req.body.len.int64 < contentLength:
                    req.respond(408, $(%*{"error": "Request timeout"}))
                    return

        gHandler(req)
        if not req.responded:
            req.respond(500, $(%*{"error": "No response"}))
    except CatchableError:
        swallowException:
            if not req.responded: req.respond(500, $(%*{"error": "Internal server error"}))
    finally:
        # Remove the body temp file however it came to exist: either the spill path above
        # (bodyTemp) or one that bodyFile() materialised for a small in-memory body. Both live in
        # req.bodyFilePath, so cleaning that up covers the small-upload case too (previously only
        # the spill path was removed, orphaning a temp file on every small multipart upload).
        if req.bodyFilePath.len > 0:
            swallowException: removeFile(req.bodyFilePath)
        swallowException: sock.close()

# ---- server loop -----------------------------------------------------------

var gListener: Socket

proc workerLoop() {.thread.} =
    # gListener/gHandler/gBodySpillThreshold/gMaxBodyBytes/gRequestTimeoutMs are all set once in
    # listenAndServe() before any worker starts and only read here; accept() is thread-safe on Linux.
    {.cast(gcsafe).}:
        while true:
            var client: Socket
            var address = ""
            try:
                gListener.acceptAddr(client, address)
            except CatchableError:
                continue
            handleConnection(client, address)

proc listenAndServe*(port: int, numThreads: int, bodySpillThreshold: int,
                     maxBodyBytes: int64, requestTimeoutMs: int, handler: RequestHandler) =
    ## Binds 0.0.0.0:port and runs `numThreads` accept/handle worker threads (blocking).
    gHandler = handler
    gBodySpillThreshold = bodySpillThreshold
    gMaxBodyBytes = maxBodyBytes
    gRequestTimeoutMs = requestTimeoutMs

    # buffered = false is REQUIRED, not an optimisation. std/net's default buffered
    # Socket is built for its buffered read helpers (recvLine etc.); this server does
    # its own framing with raw recv(ptr,len) + manual send + immediate close(). On a
    # buffered socket that combination discards the response at close time (client sees
    # a reset / 0 bytes — the "HTTP 000" bug). acceptAddr inherits isBuffered from the
    # listener, so making the listener unbuffered makes every accepted connection work.
    gListener = newSocket(buffered = false)
    gListener.setSockOpt(OptReuseAddr, true)
    gListener.bindAddr(Port(port), "0.0.0.0")
    gListener.listen()

    let n = max(1, numThreads)
    var threads = newSeq[Thread[void]](n)
    for i in 0 ..< n:
        createThread(threads[i], workerLoop)
    joinThreads(threads)
