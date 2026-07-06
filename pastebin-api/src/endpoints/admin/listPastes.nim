## GET /api/admin/pastes — every paste regardless of visibility, newest first (admin only).

import std/json
import ../context, guard
import ../../types, ../../db, ../../json

serialize(AdminPasteRow)

func adminPastesJson(rows: seq[AdminPasteRow]): string

proc handleAdminListPastes*(ctx: Ctx) =
    if not ctx.requireAdmin(): return
    ctx.req.respond(200, adminPastesJson(selectAllPastes()))

func adminPastesJson(rows: seq[AdminPasteRow]): string =
    ## Admin-only paste list (fields no public builder emits: ownerIp, hasBlob).
    var arr = newJArray()
    for r in rows: arr.add adminPasteRowNode(r)
    $arr
