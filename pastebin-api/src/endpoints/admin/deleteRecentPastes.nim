## DELETE /api/admin/pastes?last=N — admin bulk-delete the N most-recent pastes.
## One DB transaction (see db.deleteRecentPastes) instead of N single-row deletes, so clearing a
## burst of test/junk pastes is fast rather than grinding SQLite's single writer one fsync at a time.
## Mirrors the single-paste delete's cleanup: each removed paste is evicted from the in-memory cache
## and its backing blob (if any) deleted.

import std/[json, strutils]
import ../routes, guard
import ../../types
referencing db
referencing blobstore
referencing pastecache

const MaxDeleteLast = 1000   ## safety cap on a single bulk-delete request

proc handleAdminDeleteRecentPastes*(ctx: Ctx) =
    returnif: not ctx.requireAdmin()
    let lp = ctx.req.queryParam("last")
    var n = 0
    if lp.len > 0:
        try: n = parseInt(lp)
        except ValueError: n = 0
    if n <= 0:
        ctx.respondError(400, "Query param 'last' must be a positive integer")
        return
    n = min(n, MaxDeleteLast)
    let deleted = db.deleteRecentPastes(n)
    for d in deleted:
        discard pastecache.removeFromCache(d.id)      # drop the cached copy if still resident
        if d.blobId.len > 0: discard blobstore.deleteBlob(d.blobId)
    ctx.req.respond(200, $(%*{"deleted": deleted.len}))
