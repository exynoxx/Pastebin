## Domain records for the Nim backend.
## createdAt / uploadedAt are Unix epoch milliseconds, UTC (see timeutil.nim).

type
    # Two-valued visibility. The enum's string values ARE the wire values, so `$v` / JSON / SQL
    # all render "public"/"private" with no extra mapping (see normalizeVisibility for decoding).
    Visibility* = enum
        Public = "public"
        Private = "private"

    # Internal on-disk blob key (32 hex chars), a distinct type from the public base62 resource id
    # so the two — which coexist on Paste/StoredFile and address different subsystems (SQLite vs the
    # filesystem) — can't be swapped at a call site. The default "" means "inline, no blob".
    BlobId* = distinct string

    Paste* = object
        id*: string
        title*: string
        content*: string      ## full text when inline, else a preview
        size*: int64          ## total content size in bytes
        isTruncated*: bool     ## true => content is only a preview
        createdAt*: int64      ## Unix epoch milliseconds, UTC
        visibility*: Visibility
        blobId*: BlobId        ## internal: "" when inline. Never emitted in JSON.

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
        visibility*: Visibility
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
        visibility*: Visibility  ## Public => listed in recent list; Private => unlisted (direct link only)
        blobId*: BlobId        ## internal. Never emitted in JSON.

    # Result of resolving a downloadable file to its on-disk blob.
    DownloadData* = object
        contentType*: string
        fileName*: string
        blobPath*: string

func len*(b: BlobId): int {.borrow.}
    ## The only string op BlobId needs to expose (inline-vs-blob checks: `blobId.len == 0`).

func normalizeVisibility*(v: string): Visibility =
    ## The single source of truth for decoding the visibility field from untrusted input OR a DB
    ## cell: anything that isn't the literal "private" is treated as public. Shared by every
    ## create/upload handler and the db reader so the rule isn't re-spelled (and can't drift).
    if v == "private": Private else: Public
