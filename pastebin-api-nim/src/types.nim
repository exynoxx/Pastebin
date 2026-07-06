## Domain records for the Nim backend.
## createdAt / uploadedAt are Unix epoch milliseconds, UTC (see timeutil.nim).

type
    Paste* = object
        id*: string
        title*: string
        content*: string      ## full text when inline, else a preview
        size*: int64          ## total content size in bytes
        isTruncated*: bool     ## true => content is only a preview
        createdAt*: int64      ## Unix epoch milliseconds, UTC
        visibility*: string    ## "public" | "private"
        blobId*: string        ## internal: "" when inline. Never emitted in JSON.

    # Admin listing row: every paste regardless of visibility, plus owner_ip and
    # a blob-backed flag. Only used by GET /api/admin/pastes (see endpoints/admin/listPastes).
    AdminPasteRow* = object
        id*: string
        title*: string
        size*: int64
        isTruncated*: bool
        hasBlob*: bool         ## blob_id != '' => stored on disk vs inline
        createdAt*: int64      ## Unix epoch milliseconds, UTC
        visibility*: string    ## "public" | "private"
        ownerIp*: string       ## the IP that created the paste

    PasteSummary* = object
        id*: string
        title*: string
        size*: int64
        createdAt*: int64      ## Unix epoch milliseconds, UTC
        kind*: string          ## "paste" | "file"
        contentType*: string   ## MIME for files; "" for pastes

    StoredFile* = object
        id*: string
        originalName*: string
        contentType*: string
        size*: int64
        uploadedAt*: int64     ## Unix epoch milliseconds, UTC
        visibility*: string    ## "public" => listed in recent list; "private" => unlisted (direct link only)
        blobId*: string        ## internal. Never emitted in JSON.

    # Result of resolving a downloadable blob/inline paste (mirrors FileDownloadData.cs).
    # Either backed by an on-disk blob (dkBlob) or by in-memory bytes (dkInline).
    DownloadKind* = enum dkBlob, dkInline
    DownloadData* = object
        contentType*: string
        fileName*: string
        case kind*: DownloadKind
        of dkBlob:   blobPath*: string   ## on-disk blob path
        of dkInline: inlineData*: string ## in-memory bytes
