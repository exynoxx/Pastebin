## GET /api/admin/pastes — every paste regardless of visibility, newest first (admin only).

import ../context
import ../../db

proc handleAdminListPastes*(ctx: Ctx) =
    ctx.req.respond(200, adminPastesJson(selectAllPastes()))
