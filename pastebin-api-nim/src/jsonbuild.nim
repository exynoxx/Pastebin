## camelCase JSON response builders, matching ASP.NET's default System.Text.Json output.
## blobId / ownerIp are never emitted; contentType is JSON null (not "") for pastes.

import std/json
import types

proc errorJson*(msg: string): string =
    ## {"error": "..."} — the shared error envelope used across all endpoints.
    $(%*{"error": msg})

proc pasteJson*(p: Paste): string =
    ## GET /api/pastes/{id} — Paste with [JsonIgnore] BlobId omitted.
    $(%*{
        "id": p.id,
        "title": p.title,
        "content": p.content,
        "size": p.size,
        "isTruncated": p.isTruncated,
        "createdAt": p.createdAt,
        "visibility": p.visibility,
    })

proc summariesJson*(items: seq[PasteSummary]): string =
    var arr = newJArray()
    for s in items:
        arr.add(%*{
            "id": s.id,
            "title": s.title,
            "size": s.size,
            "createdAt": s.createdAt,
            "kind": s.kind,
            "contentType": (if s.contentType.len == 0: newJNull() else: %s.contentType),
        })
    $arr

proc adminPastesJson*(rows: seq[AdminPasteRow]): string =
    ## GET /api/admin/pastes — every paste with admin-only fields (ownerIp, hasBlob).
    ## The only builder that emits ownerIp.
    var arr = newJArray()
    for r in rows:
        arr.add(%*{
            "id": r.id,
            "title": r.title,
            "size": r.size,
            "isTruncated": r.isTruncated,
            "hasBlob": r.hasBlob,
            "createdAt": r.createdAt,
            "visibility": r.visibility,
            "ownerIp": r.ownerIp,
        })
    $arr

proc storedFileJson*(f: StoredFile): string =
    ## GET /api/files/{id} — StoredFile with [JsonIgnore] BlobId omitted.
    $(%*{
        "id": f.id,
        "originalName": f.originalName,
        "contentType": f.contentType,
        "size": f.size,
        "uploadedAt": f.uploadedAt,
        "visibility": f.visibility,
    })

proc fileUploadResultJson*(f: StoredFile): string =
    ## Response of /upload and /upload-folder — same visible fields as GET /api/files/{id}.
    storedFileJson(f)
