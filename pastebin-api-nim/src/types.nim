## Domain records, mirroring pastebin-api/models/*.cs.
## createdAt / uploadedAt are opaque ISO-8601 strings (see timeutil.nim).

type
    Paste* = object
        id*: string
        title*: string
        content*: string      ## full text when inline, else a preview
        size*: int64          ## total content size in bytes
        isTruncated*: bool     ## true => content is only a preview
        createdAt*: string     ## ISO-8601 UTC
        visibility*: string    ## "public" | "private"
        blobId*: string        ## internal: "" when inline. Never emitted in JSON.

    # Admin listing row: every paste regardless of visibility, plus owner_ip and
    # a blob-backed flag. Only used by GET /api/admin/pastes (see jsonbuild.adminPastesJson).
    AdminPasteRow* = object
        id*: string
        title*: string
        size*: int64
        isTruncated*: bool
        hasBlob*: bool         ## blob_id != '' => stored on disk vs inline
        createdAt*: string     ## ISO-8601 UTC
        visibility*: string    ## "public" | "private"
        ownerIp*: string       ## the IP that created the paste

    PasteSummary* = object
        id*: string
        title*: string
        size*: int64
        createdAt*: string
        kind*: string          ## "paste" | "file"
        contentType*: string   ## MIME for files; "" (=> null in JSON) for pastes

    StoredFile* = object
        id*: string
        originalName*: string
        contentType*: string
        size*: int64
        uploadedAt*: string    ## ISO-8601 UTC
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
