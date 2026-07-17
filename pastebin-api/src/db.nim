## SQLite data-access layer — the ONE place that knows SQL.
##
## This is the app's "reader": every `sql"..."` statement, the `db_sqlite` dependency, the
## connection pool and the write lock live here. The rest of the code (services, quota, router)
## depends only on the typed operations exposed at the bottom (selectPaste, insertFile, …) and
## never sees a row, a column index, or a query — so the storage engine can change behind this
## boundary without touching business logic. Mirrors pastebin-api/services/SqliteConnectionFactory.cs.
##
## WAL gives concurrent readers + a single writer. SQLite connections are not shareable across
## threads, so each worker lazily opens its OWN connection (thread-local). A process-wide write
## mutex serialises inserts/deletes to keep SQLITE_BUSY churn off the SD card (busy_timeout is
## the backstop).

import std/[locks, os, strutils, options]
import db_connector/db_sqlite
import types

var
    gDbPath: string
    gWriteLock: Lock

var
    tlConn {.threadvar.}: DbConn
    tlOpen {.threadvar.}: bool

func int64OrZero(cell: string): int64 =
    ## A possibly-empty SQLite text cell (NULL/absent surfaces as "") decoded as int64,
    ## defaulting to 0 — the read-side mirror of the schema's `COALESCE(SUM(size), 0)`.
    if cell.len == 0: 0'i64 else: parseBiggestInt(cell).int64

proc openConn(path: string): DbConn =
    result = open(path, "", "", "")
    # Wait briefly for a lock instead of failing immediately (WAL already lets readers run).
    result.exec(sql"PRAGMA busy_timeout = 5000;")

proc columnExists(db: DbConn, table, column: string): bool =
    # PRAGMA table_info: cid, name, type, notnull, dflt_value, pk — name is index 1.
    for row in db.fastRows(sql("PRAGMA table_info(" & table & ");")):
        if cmpIgnoreCase(row[1], column) == 0:
            return true
    false

proc addColumnIfMissing(db: DbConn, table, column, typ: string) =
    ## SQLite has no "ADD COLUMN IF NOT EXISTS"; add only when absent (idempotent migration).
    if db.columnExists(table, column): return
    db.exec(sql("ALTER TABLE " & table & " ADD COLUMN " & column & " " & typ & ";"))

proc initDb*(sqlitePath: string) =
    ## Run once at startup: create the data dir, open a bootstrap connection, set PRAGMAs and
    ## create/migrate the schema.
    gDbPath = sqlitePath
    let dir = parentDir(sqlitePath)
    if dir.len > 0: createDir(dir)
    initLock(gWriteLock)

    let db = openConn(sqlitePath)
    defer: db.close()

    # WAL = concurrent reads during writes; NORMAL is the safe, SD-card-gentle pairing with WAL.
    db.exec(sql"PRAGMA journal_mode = WAL;")
    db.exec(sql"PRAGMA synchronous = NORMAL;")

    db.exec(sql"""
        CREATE TABLE IF NOT EXISTS pastes (
                id           TEXT PRIMARY KEY,
                title        TEXT NOT NULL,
                content      TEXT NOT NULL,
                size         INTEGER NOT NULL,
                is_truncated INTEGER NOT NULL,
                created_at   INTEGER NOT NULL,
                blob_id      TEXT NULL,
                visibility   TEXT NOT NULL DEFAULT 'public'
        );
    """)
    db.exec(sql"CREATE INDEX IF NOT EXISTS ix_pastes_created_at ON pastes (created_at DESC);")
    db.exec(sql"""
        CREATE TABLE IF NOT EXISTS files (
                id            TEXT PRIMARY KEY,
                original_name TEXT NOT NULL,
                content_type  TEXT NOT NULL,
                size          INTEGER NOT NULL,
                uploaded_at   INTEGER NOT NULL,
                blob_id       TEXT NOT NULL,
                visibility    TEXT NOT NULL DEFAULT 'public'
        );
    """)

    # Idempotent migrations for DBs created by older builds.
    db.addColumnIfMissing("pastes", "owner_ip", "TEXT")
    db.addColumnIfMissing("files", "owner_ip", "TEXT")
    db.addColumnIfMissing("pastes", "visibility", "TEXT NOT NULL DEFAULT 'public'")
    db.addColumnIfMissing("files", "visibility", "TEXT NOT NULL DEFAULT 'public'")

    db.exec(sql"CREATE INDEX IF NOT EXISTS ix_pastes_owner_ip ON pastes (owner_ip);")
    db.exec(sql"CREATE INDEX IF NOT EXISTS ix_files_owner_ip ON files (owner_ip);")

proc conn(): DbConn =
    ## The calling worker thread's lazily-opened connection.
    if not tlOpen:
        tlConn = openConn(gDbPath)
        tlOpen = true
    tlConn

# ---- typed operations (the public reader API) ------------------------------
# Everything below returns/accepts domain types from types.nim; no SQL, row, or
# column index escapes this module.

proc insertPaste*(p: Paste, ownerIp: string) =
    ## Persist a paste row. blob_id is stored as SQL NULL for inline pastes (blobId == "").
    withLock gWriteLock:  # serialise writers process-wide (single-writer WAL discipline)
        if p.blobId.len == 0:
            conn().exec(sql"""
                INSERT INTO pastes (id, title, content, size, is_truncated, created_at, blob_id, owner_ip, visibility)
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?);
            """, p.id, p.title, p.content, $p.size, $ord(p.isTruncated),
                $p.createdAt, ownerIp, $p.visibility)
        else:
            conn().exec(sql"""
                INSERT INTO pastes (id, title, content, size, is_truncated, created_at, blob_id, owner_ip, visibility)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, p.id, p.title, p.content, $p.size, $ord(p.isTruncated),
                $p.createdAt, p.blobId.string, ownerIp, $p.visibility)

proc selectPaste*(id: string): Option[Paste] =
    let rows = conn().getAllRows(sql"""
        SELECT id, title, content, size, is_truncated, created_at, blob_id, visibility
        FROM pastes WHERE id = ? LIMIT 1;
    """, id)
    if rows.len == 0: return none(Paste)
    let r = rows[0]
    let paste = Paste(
        id: r[0], title: r[1], content: r[2],
        size: int64OrZero(r[3]),
        isTruncated: int64OrZero(r[4]) != 0,
        createdAt: int64OrZero(r[5]),
        blobId: BlobId(r[6]),
        visibility: normalizeVisibility(r[7]))
    some(paste)

proc selectRecentSummaries*(limit: int): seq[PasteSummary] =
    ## Newest-first mix of public pastes and public files (content_type NULL for pastes).
    let rows = conn().getAllRows(sql"""
        SELECT id, title, size, created_at, 'paste' AS kind, NULL AS content_type
        FROM pastes WHERE visibility = 'public'
        UNION ALL
        SELECT id, original_name AS title, size, uploaded_at AS created_at, 'file' AS kind, content_type
        FROM files WHERE visibility = 'public'
        ORDER BY created_at DESC LIMIT ?;
    """, $limit)
    for r in rows:
        result.add PasteSummary(
            id: r[0], title: r[1],
            size: int64OrZero(r[2]),
            createdAt: int64OrZero(r[3]), kind: r[4],
            contentType: r[5])  # "" (NULL) for pastes

proc selectAllContent*(): seq[AdminContentRow] =
    ## Admin view: every paste AND file (no visibility filter), newest first, including owner_ip.
    let rows = conn().getAllRows(sql"""
        SELECT id, 'paste' AS kind, title AS name, '' AS content_type, size, is_truncated,
               blob_id, created_at, visibility, owner_ip
        FROM pastes
        UNION ALL
        SELECT id, 'file' AS kind, original_name AS name, content_type, size, 0 AS is_truncated,
               blob_id, uploaded_at AS created_at, visibility, owner_ip
        FROM files
        ORDER BY created_at DESC;
    """)
    for r in rows:
        result.add AdminContentRow(
            id: r[0], kind: r[1], title: r[2], contentType: r[3],
            size: int64OrZero(r[4]),
            isTruncated: int64OrZero(r[5]) != 0,
            hasBlob: r[6].len > 0,   # blob_id NULL/"" => inline
            createdAt: int64OrZero(r[7]),
            visibility: normalizeVisibility(r[8]),
            ownerIp: r[9])

proc deletePasteRow*(id: string): bool =
    ## Delete a paste's row; true when a row was actually removed.
    var affected: int64 = 0
    withLock gWriteLock:
        affected = conn().execAffectedRows(sql"DELETE FROM pastes WHERE id = ?;", id)
    affected > 0

proc insertFile*(f: StoredFile, ownerIp: string) =
    ## Persist a file metadata row (the blob itself is written separately by the blob store).
    withLock gWriteLock:
        conn().exec(sql"""
            INSERT INTO files (id, original_name, content_type, size, uploaded_at, blob_id, owner_ip, visibility)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, f.id, f.originalName, f.contentType, $f.size, $f.uploadedAt, f.blobId.string, ownerIp, $f.visibility)

proc selectFile*(id: string): Option[StoredFile] =
    let rows = conn().getAllRows(sql"""
        SELECT id, original_name, content_type, size, uploaded_at, blob_id, visibility
        FROM files WHERE id = ? LIMIT 1;
    """, id)
    if rows.len == 0: return none(StoredFile)
    let r = rows[0]
    let stored = StoredFile(
        id: r[0], originalName: r[1], contentType: r[2],
        size: int64OrZero(r[3]),
        uploadedAt: int64OrZero(r[4]), blobId: BlobId(r[5]), visibility: normalizeVisibility(r[6]))
    some(stored)

proc deleteFileRow*(id: string): bool =
    ## Delete a file's metadata row; true when a row was actually removed.
    var affected: int64 = 0
    withLock gWriteLock:
        affected = conn().execAffectedRows(sql"DELETE FROM files WHERE id = ?;", id)
    affected > 0

proc sumUsageForOwner*(ownerIp: string): int64 =
    ## Total stored bytes (pastes + files) attributed to one owner IP, for quota checks.
    let v = conn().getValue(sql"""
        SELECT
                (SELECT COALESCE(SUM(size), 0) FROM pastes WHERE owner_ip = ?)
            + (SELECT COALESCE(SUM(size), 0) FROM files  WHERE owner_ip = ?);
    """, ownerIp, ownerIp)
    int64OrZero(v)
