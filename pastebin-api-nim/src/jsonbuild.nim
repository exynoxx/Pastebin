## camelCase JSON response builders, matching ASP.NET's default System.Text.Json output.
## blobId / ownerIp are never emitted; contentType is JSON null (not "") for pastes.

import std/json
import types

{.push raises: [].}   # nothing in this module may throw — pure JSON builders

# The shared {"error": ...} envelope lives in the framework (framework/context.errorJson).

func pasteJson*(p: Paste): string =
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

func summariesJson*(items: seq[PasteSummary]): string =
    # Explicit accumulation, not `collect`: JsonNode isn't a collect-supported
    # container, and this is a per-request response path (guide §10 RSS caveat).
    var arr = newJArray()
    for s in items:
        arr.add %*{
            "id": s.id,
            "title": s.title,
            "size": s.size,
            "createdAt": s.createdAt,
            "kind": s.kind,
            "contentType": (if s.contentType.len == 0: newJNull() else: %s.contentType),
        }
    $arr

func adminPastesJson*(rows: seq[AdminPasteRow]): string =
    ## GET /api/admin/pastes — every paste with admin-only fields (ownerIp, hasBlob).
    ## The only builder that emits ownerIp.
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

func storedFileJson*(f: StoredFile): string =
    ## GET /api/files/{id} — StoredFile with [JsonIgnore] BlobId omitted.
    $(%*{
        "id": f.id,
        "originalName": f.originalName,
        "contentType": f.contentType,
        "size": f.size,
        "uploadedAt": f.uploadedAt,
        "visibility": f.visibility,
    })

func fileUploadResultJson*(f: StoredFile): string =
    ## Response of /upload and /upload-folder — same visible fields as GET /api/files/{id}.
    storedFileJson(f)

{.pop.}
