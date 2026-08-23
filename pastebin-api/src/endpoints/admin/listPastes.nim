## GET /api/admin/pastes — every paste AND file regardless of visibility, newest first (admin only).

import ../routes, guard
import ../../json
referencing db

proc handleAdminListPastes*(ctx: Ctx) =
    returnif: not ctx.requireAdmin()
    ctx.req.respond(200, adminContentJson(db.selectAllContent()))
