## GET /api/admin/pastes — every paste regardless of visibility, newest first (admin only).

import std/json
import ../context, guard
import ../../types, ../../db

func adminPastesJson(rows: seq[AdminPasteRow]): string =
    ## Admin-only paste list with fields no public builder emits (ownerIp, hasBlob).
    var arr = newJArray()
    for r in rows:
        arr.add %*{
            "id": r.id,
            "title": r.title,
            "size": r.size,
            "isTruncated": r.isTruncated,
            "hasBlob": r.hasBlob,
            "createdAt": r.createdAt,
            "visibility": r.visibility,
            "ownerIp": r.ownerIp,
        }
    $arr

proc handleAdminListPastes*(ctx: Ctx) =
    if not ctx.requireAdmin(): return
    ctx.req.respond(200, adminPastesJson(selectAllPastes()))
