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

import std/[net, os, strutils, monotimes, uri, json]

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

    RequestHandler* = proc(req: Request) {.nimcall, gcsafe.}

const
    RecvChunk = 64 * 1024
    SendChunk = 1 shl 20              # 1 MB streaming buffer for respondFile

var
    gHandler: RequestHandler
    gBodySpillThreshold: int
    gMaxBodyBytes: int64

func reason(code: int): string =
    ## Reason phrase for the status codes this app emits. A case (not a global Table) keeps the
    ## proc GC-safe so it can run on the worker threads.
    case code
    of 200: "OK"
    of 206: "Partial Content"
    of 400: "Bad Request"
    of 404: "Not Found"
    of 413: "Payload Too Large"
    of 416: "Range Not Satisfiable"
    of 429: "Too Many Requests"
    of 500: "Internal Server Error"
    of 503: "Service Unavailable"
    else: "OK"

# ---- request helpers -------------------------------------------------------

proc header*(req: Request, name: string): string =
    ## Case-insensitive header lookup; "" if absent (matches webby/.NET semantics).
    for (k, v) in req.headers:
        if cmpIgnoreCase(k, name) == 0:
            return v
    ""

proc uniqueTempPath(): string   # fwd decl (defined below, near request reading)

proc bodyString*(req: Request): string =
    ## Full request body in memory, reading the spill file if the body was spilled to disk.
    ## For endpoints that must parse the whole body (e.g. JSON). Bounded by the route's limits.
    if req.bodyFilePath.len > 0: readFile(req.bodyFilePath) else: req.body

proc bodyFile*(req: Request): string =
    ## Path to a file holding the full body, materialising one from the in-memory body when the
    ## body wasn't spilled. Sets req.bodyFilePath so the server's cleanup removes it. Used for
    ## streaming multipart parsing.
    if req.bodyFilePath.len == 0:
        let p = uniqueTempPath()
        writeFile(p, req.body)
        req.bodyFilePath = p
        req.body = ""
    req.bodyFilePath

proc queryParam*(req: Request, name: string): string =
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

proc writeStatusAndHeaders(sock: Socket, code: int,
                           headers: seq[(string, string)]) =
    var head = "HTTP/1.1 " & $code & " " & reason(code) & "\r\n"
    for (k, v) in headers:
        head.add k & ": " & v & "\r\n"
    head.add "Connection: close\r\n\r\n"
    sock.sendAll(head)

proc respond*(req: Request, statusCode: int, body: string,
              contentType = "application/json; charset=utf-8",
              extraHeaders: openArray[(string, string)] = []) =
    ## Buffered response (JSON / small text). Sets Content-Type + Content-Length.
    if req.responded: return
    req.responded = true
    var hs: seq[(string, string)]
    hs.add ("Content-Type", contentType)
    hs.add ("Content-Length", $body.len)
    for h in extraHeaders: hs.add h
    try:
        writeStatusAndHeaders(req.socket, statusCode, hs)
        req.socket.sendAll(body)
    except CatchableError:
        discard # peer disconnected before/while receiving the response

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
    var buf = newString(SendChunk)
    while remaining > 0:
        let want = int(min(remaining, SendChunk.int64))
        let n = f.readBuffer(addr buf[0], want)
        if n <= 0: break
        if n == buf.len: sock.send(buf)
        else: sock.send(buf[0 ..< n])
        remaining -= n

proc respondFile*(req: Request, path, contentType: string,
                  rangeHeader = "", contentDisposition = "", noSniff = false) =
    ## Streams a file from disk with optional single-range support. 404 if unreadable.
    if req.responded: return
    req.responded = true

    var f: File
    if not open(f, path, fmRead):
        let body = $(%*{"error": "Not found"})
        try:
            writeStatusAndHeaders(req.socket, 404,
                @[("Content-Type", "application/json; charset=utf-8"),
                    ("Content-Length", $body.len)])
            req.socket.sendAll(body)
        except CatchableError: discard
        return
    defer: f.close()

    let size = f.getFileSize()
    var hs: seq[(string, string)]
    hs.add ("Content-Type", contentType)
    hs.add ("Accept-Ranges", "bytes")
    if contentDisposition.len > 0: hs.add ("Content-Disposition", contentDisposition)
    if noSniff: hs.add ("X-Content-Type-Options", "nosniff")

    try:
        let r = parseSingleRange(rangeHeader, size)
        if r.ok and not r.satisfiable:
            hs.add ("Content-Range", "bytes */" & $size)
            hs.add ("Content-Length", "0")
            writeStatusAndHeaders(req.socket, 416, hs)
            return
        if r.ok and r.satisfiable:
            let count = r.last - r.first + 1
            hs.add ("Content-Range", "bytes " & $r.first & "-" & $r.last & "/" & $size)
            hs.add ("Content-Length", $count)
            writeStatusAndHeaders(req.socket, 206, hs)
            streamFileRange(req.socket, f, r.first, count)
        else:
            hs.add ("Content-Length", $size)
            writeStatusAndHeaders(req.socket, 200, hs)
            streamFileRange(req.socket, f, 0, size)
    except CatchableError:
        discard # peer disconnected mid-stream

# ---- request reading -------------------------------------------------------

proc uniqueTempPath(): string =
    var n {.global.}: int
    # No PRNG (Math.random is unavailable): pid + monotonic ticks + a counter.
    inc n
    getTempDir() / ("pb-body-" & $getCurrentProcessId() & "-" &
        $getMonoTime().ticks & "-" & $n & ".tmp")

proc recvInto(sock: Socket, buf: var string): int =
    ## Reads up to RecvChunk bytes; returns 0 on clean EOF.
    buf.setLen(RecvChunk)
    let n = sock.recv(addr buf[0], RecvChunk)
    if n <= 0: 0 else: n

proc handleConnection(sock: Socket, remote: string) =
    ## Reads exactly one request, dispatches it, cleans up. Never raises.
    var req = Request(socket: sock, remoteAddress: remote)
    var bodyTemp = ""
    try:
        # --- read the header block (until CRLF CRLF), keeping any body bytes read past it ---
        var pending = ""
        var headerEnd = -1
        var chunk = newString(RecvChunk)
        while headerEnd < 0:
            let n = sock.recv(addr chunk[0], RecvChunk)
            if n <= 0: break
            pending.add chunk[0 ..< n]
            headerEnd = pending.find("\r\n\r\n")
            if pending.len > 64 * 1024 and headerEnd < 0:
                req.respond(400, $(%*{"error": "Header too large"}))
                return
        if headerEnd < 0:
            return # connection closed before a full header block

        let headerText = pending[0 ..< headerEnd]
        var leftover = pending[headerEnd + 4 .. ^1]  # first body bytes already received

        # --- parse request line + headers ---
        let lines = headerText.split("\r\n")
        if lines.len == 0 or lines[0].len == 0:
            req.respond(400, $(%*{"error": "Bad request"}))
            return
        let parts = lines[0].split(' ')
        if parts.len < 2:
            req.respond(400, $(%*{"error": "Bad request"}))
            return
        req.httpMethod = parts[0]
        let uri = parts[1]
        let q = uri.find('?')
        if q >= 0:
            req.path = uri[0 ..< q].decodeUrl()
            req.rawQuery = uri[q + 1 .. ^1]
        else:
            req.path = uri.decodeUrl()
        for i in 1 ..< lines.len:
            let line = lines[i]
            let colon = line.find(':')
            if colon > 0:
                req.headers.add (line[0 ..< colon].strip(), line[colon + 1 .. ^1].strip())

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
                bodyTemp = uniqueTempPath()
                req.bodyFilePath = bodyTemp
                let outF = open(bodyTemp, fmWrite)
                var received: int64 = 0
                if leftover.len > 0:
                    discard outF.writeBuffer(addr leftover[0], leftover.len)
                    received = leftover.len.int64
                while received < contentLength:
                    let want = int(min((contentLength - received), RecvChunk.int64))
                    chunk.setLen(RecvChunk)
                    let n = sock.recv(addr chunk[0], want)
                    if n <= 0: break
                    discard outF.writeBuffer(addr chunk[0], n)
                    received += n
                outF.close()
            else:
                # Small body: read into memory.
                req.body = leftover
                while req.body.len.int64 < contentLength:
                    let want = int(min((contentLength - req.body.len.int64), RecvChunk.int64))
                    chunk.setLen(RecvChunk)
                    let n = sock.recv(addr chunk[0], want)
                    if n <= 0: break
                    req.body.add chunk[0 ..< n]

        gHandler(req)
        if not req.responded:
            req.respond(500, $(%*{"error": "No response"}))
    except CatchableError:
        try:
            if not req.responded: req.respond(500, $(%*{"error": "Internal server error"}))
        except CatchableError: discard
    finally:
        if bodyTemp.len > 0:
            try: removeFile(bodyTemp)
            except CatchableError: discard
        try: sock.close()
        except CatchableError: discard

# ---- server loop -----------------------------------------------------------

var gListener: Socket

proc workerLoop() {.thread.} =
    # gListener/gHandler/gBodySpillThreshold/gMaxBodyBytes are all set once in listenAndServe()
    # before any worker starts and only read here; accept() is thread-safe across workers on Linux.
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
                     maxBodyBytes: int64, handler: RequestHandler) =
    ## Binds 0.0.0.0:port and runs `numThreads` accept/handle worker threads (blocking).
    gHandler = handler
    gBodySpillThreshold = bodySpillThreshold
    gMaxBodyBytes = maxBodyBytes

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
