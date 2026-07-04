## Chunked `multipart/form-data` parser.
##
## The request body is already spilled to a file on disk (see the body-buffering middleware),
## so this reads it back in bounded chunks and NEVER loads the whole body into memory. File
## parts are streamed straight to their own temp files; small non-file fields are captured in
## `value`.
##
## Boundary scanning is the crux. We search the stream for the needle `"\n--<boundary>"`:
##   * A spec CRLF delimiter is `"\r\n--<boundary>"`, which *contains* `"\n--<boundary>"`, so the
##     same needle matches both CRLF and (tolerated) LF-only bodies. The stray leading `\r` that a
##     CRLF body leaves at the tail of the part body is trimmed off afterwards.
##   * The very first delimiter has no preceding line break, so we seed the read buffer with a
##     single `"\n"` — that makes a body starting with `--<boundary>` match at offset 0 while any
##     preamble in front of it is harmlessly discarded.
## The scan carries over the last `needle.len - 1` bytes between chunk reads, which is exactly the
## amount needed so a delimiter split across two `readBuffer` calls is still found.

import std/[os, strutils, monotimes]

type
    MultipartEntry* = object
        name*: string          ## form field name (from Content-Disposition name="...")
        filename*: string      ## filename="..." if present, else ""
        contentType*: string   ## the part's Content-Type header, else ""
        isFile*: bool          ## true when a filename was present on the part
        value*: string         ## for NON-file fields: the field's text value (in memory)
        dataFilePath*: string  ## for FILE fields: path to a temp file holding the part's raw bytes
        size*: int64           ## byte length of the file part (0 for non-file fields)

    MultipartError* = object of CatchableError

const
    ChunkSize = 1 shl 16              ## 64 KB read buffer — bounded regardless of body size.
    MaxHeaderBytes = 64 * 1024        ## cap on a single part's header block (anti-OOM on malformed input).
    MaxFieldValueBytes = 1'i64 shl 20 ## 1 MB cap on an in-memory (non-file) field value.
    MaxBoundaryLine = 4096            ## a boundary/delimiter line should be tiny.

type
    Scanner = ref object
        ## Buffered forward reader over the body file. `buf[pos ..< buf.len]` is the unconsumed
        ## window; `buf[0 ..< pos]` is already handed out and may be dropped on the next refill.
        f: File
        buf: string
        pos: int
        eof: bool

# ---------------------------------------------------------------------------
# Low-level scanner
# ---------------------------------------------------------------------------

proc fillChunk(s: Scanner) =
    ## Drop the already-consumed prefix, then append one more chunk from the file.
    if s.eof: return
    if s.pos > 0:
        s.buf = s.buf.substr(s.pos)  # unconsumed tail is small (<= needle.len-1), cheap to copy
        s.pos = 0
    let start = s.buf.len
    s.buf.setLen(start + ChunkSize)
    let got = s.f.readBuffer(addr s.buf[start], ChunkSize)
    s.buf.setLen(start + got)
    if got == 0: s.eof = true

proc writeExact(f: File, d: openArray[char], lo, hi: int) =
    ## Write d[lo..hi] (inclusive) in full, retrying short writes like BlobStore does.
    var i = lo
    while i <= hi:
        let n = f.writeBuffer(unsafeAddr d[i], hi - i + 1)
        if n <= 0:
            raise newException(MultipartError, "failed writing multipart temp file")
        i += n

proc appendTo(s: var string, d: openArray[char]) =
    ## Append an openArray[char] to a string via a single copy.
    if d.len == 0: return
    let start = s.len
    s.setLen(start + d.len)
    copyMem(addr s[start], unsafeAddr d[0], d.len)

proc copyUntilNeedle(s: Scanner, needle: string, sink: proc(d: openArray[char])): bool =
    ## Stream bytes to `sink` until `needle` is found (the needle is consumed, NOT emitted).
    ## Returns true if the needle was found, false if EOF was hit first (in which case all
    ## remaining bytes are emitted). Memory stays bounded: at most one chunk plus a
    ## `needle.len - 1` carry-over lives in `buf` at any time.
    while true:
        let idx = s.buf.find(needle, s.pos)
        if idx >= 0:
            if idx > s.pos: sink(s.buf.toOpenArray(s.pos, idx - 1))
            s.pos = idx + needle.len
            return true
        if s.eof:
            if s.buf.len > s.pos: sink(s.buf.toOpenArray(s.pos, s.buf.len - 1))
            s.pos = s.buf.len
            return false
        # No match yet. Emit everything except the trailing needle.len-1 bytes — those could be the
        # start of a needle that continues into the next chunk, so we hold them back and re-scan.
        let avail = s.buf.len - s.pos
        let keep = min(needle.len - 1, avail)
        let emitEnd = s.buf.len - keep  # exclusive
        if emitEnd > s.pos:
            sink(s.buf.toOpenArray(s.pos, emitEnd - 1))
            s.pos = emitEnd
        fillChunk(s)

proc readLine2(s: Scanner, maxLen: int): tuple[line: string, atEof: bool] =
    ## Read up to and including the next `\n`, returning the line WITHOUT its trailing CRLF/LF.
    ## `atEof` is true when the stream ended before a `\n` was seen. Raises if the line exceeds
    ## `maxLen` (guards against a part with no line breaks eating all memory).
    var res = ""
    while true:
        let idx = s.buf.find('\n', s.pos)
        if idx >= 0:
            res.add s.buf[s.pos ..< idx]
            s.pos = idx + 1
            if res.len > 0 and res[^1] == '\r': res.setLen(res.len - 1)
            return (res, false)
        if s.buf.len > s.pos:
            res.add s.buf[s.pos ..< s.buf.len]
            s.pos = s.buf.len
        if res.len > maxLen:
            raise newException(MultipartError, "multipart line exceeds maximum length")
        if s.eof:
            return (res, true)
        fillChunk(s)

# ---------------------------------------------------------------------------
# Header / boundary helpers
# ---------------------------------------------------------------------------

proc extractBoundary(contentTypeHeader: string): string =
    ## Pull the boundary token out of a Content-Type header, case-insensitively. The value may be
    ## quoted (`boundary="..."`) or bare (`boundary=...;`). Returns "" if not present.
    let lower = contentTypeHeader.toLowerAscii()
    const key = "boundary="
    let i = lower.find(key)
    if i < 0: return ""
    var v = contentTypeHeader[(i + key.len) .. ^1].strip()
    if v.len > 0 and v[0] == '"':
        let endq = v.find('"', 1)
        v = if endq > 0: v[1 ..< endq] else: v[1 .. ^1]
    else:
        let semi = v.find(';')
        if semi >= 0: v = v[0 ..< semi]
        v = v.strip()
    v

proc unquote(v: string): string =
    ## Strip a single pair (or a leading) double-quote from a header-parameter value.
    if v.len >= 2 and v[0] == '"' and v[^1] == '"': v[1 ..< v.len - 1]
    elif v.len >= 1 and v[0] == '"': v[1 .. ^1]
    else: v

proc parseDisposition(paramsPart: string): tuple[name, filename: string, hasFilename: bool] =
    ## Parse the parameters of a `Content-Disposition: form-data; name="..."; filename="..."` header.
    ## `paramsPart` is everything after the `:`. Note: a `filename` attribute (even `filename=""`)
    ## marks the part as a file, matching browser behavior.
    for rawSeg in paramsPart.split(';'):
        let seg = rawSeg.strip()
        let eq = seg.find('=')
        if eq < 0: continue
        let k = seg[0 ..< eq].strip().toLowerAscii()
        let v = unquote(seg[eq + 1 .. ^1].strip())
        if k == "name":
            result.name = v
        elif k == "filename":
            result.filename = v
            result.hasFilename = true

var gTempSeq: int  ## process-local, monotonically increasing — never repeats within a run.

proc uniqueTempPath(): string =
    ## Unique temp path under getTempDir() built WITHOUT relying on a PRNG: process id +
    ## monotonic clock ticks + an incrementing counter. Even under a concurrent-request race on
    ## the counter, the monotonic ticks differ, so collisions are not realistically possible.
    inc gTempSeq
    getTempDir() / ("pastebin-mp-" & $getCurrentProcessId() & "-" &
        $getMonoTime().ticks & "-" & $gTempSeq & ".tmp")

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc parseMultipart*(bodyPath: string, contentTypeHeader: string): seq[MultipartEntry] =
    ## Parses the multipart body stored at `bodyPath`, using the boundary from
    ## `contentTypeHeader` (e.g. `multipart/form-data; boundary=----WebKitFormBoundaryXYZ`).
    ## File parts (filename present) are streamed to their own temp files (dataFilePath);
    ## non-file parts are captured in `value`. Raises `MultipartError` on malformed input.
    let boundary = extractBoundary(contentTypeHeader)
    if boundary.len == 0:
        raise newException(MultipartError, "no multipart boundary in Content-Type header")

    # Needle intentionally uses a single leading "\n" (see module doc): it matches both the CRLF
    # delimiter "\r\n--<boundary>" and an LF-only "\n--<boundary>".
    let needle = "\n--" & boundary

    let f = open(bodyPath, fmRead)
    defer: f.close()

    # Seed the buffer with a lone "\n" so the very first delimiter (which has no preceding line
    # break) is matched by the same needle as every subsequent one.
    let s = Scanner(f: f, buf: "\n", pos: 0, eof: false)

    # Discard the preamble (if any) up to and including the first delimiter.
    if not copyUntilNeedle(s, needle, proc(d: openArray[char]) = discard):
        raise newException(MultipartError, "multipart boundary not found in body")

    while true:
        # After a delimiter's boundary token: an empty line introduces a part; "--" closes the body.
        let (marker, atEof) = readLine2(s, MaxBoundaryLine)
        let mt = marker.strip()
        if mt.startsWith("--"):
            break            # closing delimiter — ignore any epilogue
        if atEof:
            break            # truncated: delimiter with no following part

        # --- part headers (until a blank line) ---
        var entry = MultipartEntry()
        var pHasFilename = false
        var headerBytes = 0
        while true:
            let (hline, hEof) = readLine2(s, MaxHeaderBytes)
            headerBytes += hline.len + 2
            if headerBytes > MaxHeaderBytes:
                raise newException(MultipartError, "multipart part headers too large")
            if hline.strip().len == 0:
                break          # blank line terminates the header block
            let colon = hline.find(':')
            if colon >= 0:
                let hname = hline[0 ..< colon].strip().toLowerAscii()
                if hname == "content-disposition":
                    let d = parseDisposition(hline[colon + 1 .. ^1])
                    entry.name = d.name
                    entry.filename = d.filename
                    pHasFilename = d.hasFilename
                elif hname == "content-type":
                    entry.contentType = hline[colon + 1 .. ^1].strip()
            if hEof:
                break

        # --- part body (up to the next delimiter) ---
        if pHasFilename:
            entry.isFile = true
            let tmpPath = uniqueTempPath()
            entry.dataFilePath = tmpPath
            let outF = open(tmpPath, fmWrite)
            var sz: int64 = 0
            # Hold back exactly one byte: the body's final byte is the CRLF's stray "\r" for a spec
            # body and must be trimmed, but is genuine content for an LF-only body.
            var heldByte: char
            var hasHeld = false
            block:
                defer: outF.close()
                let sink = proc(d: openArray[char]) =
                    if d.len == 0: return
                    if hasHeld:
                        var one: array[1, char]
                        one[0] = heldByte
                        writeExact(outF, one, 0, 0)
                        sz += 1
                        hasHeld = false
                    if d.len >= 2:
                        writeExact(outF, d, 0, d.len - 2)
                        sz += (d.len - 1)
                    heldByte = d[d.len - 1]
                    hasHeld = true
                discard copyUntilNeedle(s, needle, sink)
                # Flush the held byte unless it is the CRLF's trailing "\r" before the delimiter.
                if hasHeld and heldByte != '\r':
                    var one: array[1, char]
                    one[0] = heldByte
                    writeExact(outF, one, 0, 0)
                    sz += 1
            entry.size = sz
        else:
            entry.isFile = false
            var val = ""
            let name = entry.name
            let sink = proc(d: openArray[char]) =
                if val.len.int64 + d.len.int64 > MaxFieldValueBytes:
                    raise newException(MultipartError, "form field '" & name & "' exceeds maximum size")
                appendTo(val, d)
            discard copyUntilNeedle(s, needle, sink)
            # Trim the single trailing "\r" left by a CRLF body (no-op for an LF-only body).
            if val.len > 0 and val[^1] == '\r':
                val.setLen(val.len - 1)
            entry.value = val

        result.add entry

proc cleanupEntries*(entries: seq[MultipartEntry]) =
    ## Best-effort delete of every entry's dataFilePath temp file. Call when done.
    for e in entries:
        if e.dataFilePath.len > 0:
            try:
                removeFile(e.dataFilePath)
            except CatchableError:
                discard
