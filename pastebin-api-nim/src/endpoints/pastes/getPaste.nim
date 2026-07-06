## GET /api/pastes/{id} — one paste's metadata + (inline) content.

import std/[json, options]
import ../context
import ../../types, ../../db

func pasteJson(p: Paste): string =
    ## Paste with [JsonIgnore] BlobId omitted. camelCase to match ASP.NET's default output.
    $(%*{
        "id": p.id,
        "title": p.title,
        "content": p.content,
        "size": p.size,
        "isTruncated": p.isTruncated,
        "createdAt": p.createdAt,
        "visibility": p.visibility,
    })

proc handleGetPaste*(ctx: Ctx) =
    let p = fetchOr404(ctx, selectPaste(ctx.params[0]), "Paste not found")
    ctx.req.respond(200, pasteJson(p))
