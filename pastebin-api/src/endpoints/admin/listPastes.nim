## GET /api/admin/pastes — every paste AND file regardless of visibility, newest first (admin only).

import std/json
import ../routes, guard
import ../../types, ../../json
importuse db

serialize(AdminContentRow)

func adminContentJson(rows: seq[AdminContentRow]): string

proc handleAdminListPastes*(ctx: Ctx) =
    returnif: not ctx.requireAdmin()
    ctx.req.respond(200, adminContentJson(db.selectAllContent()))

func adminContentJson(rows: seq[AdminContentRow]): string =
    ## Admin-only content list (fields no public builder emits: ownerIp, hasBlob).
    var arr = newJArray()
    for r in rows: arr.add adminContentRowNode(r)
    $arr
