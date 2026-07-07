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

    # Admin listing row: every paste AND file regardless of visibility, plus owner_ip and
    # a blob-backed flag. Only used by GET /api/admin/pastes (see endpoints/admin/listPastes).
    AdminContentRow* = object
        id*: string
        kind*: string          ## "paste" | "file"
        title*: string         ## paste title, or the file's original name
        contentType*: string   ## MIME for files; "" for pastes
        size*: int64
        isTruncated*: bool     ## pastes only; always false for files
        hasBlob*: bool         ## blob_id != '' => stored on disk vs inline
        createdAt*: int64      ## Unix epoch milliseconds, UTC
        visibility*: string    ## "public" | "private"
        ownerIp*: string       ## the IP that created the item

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

    # Result of resolving a downloadable file to its on-disk blob.
    DownloadData* = object
        contentType*: string
        fileName*: string
        blobPath*: string

func normalizeVisibility*(v: string): string =
    ## The single source of truth for the two-valued visibility field: anything that isn't the
    ## literal "private" is treated as "public". Shared by every create/upload handler so the
    ## rule isn't re-spelled (and can't drift) across the slices.
    if v == "private": "private" else: "public"
