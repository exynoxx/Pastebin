## Shared JSON response shaping for the files slice. `storedFileJson` is the file-metadata body
## returned by GET /api/files/{id} and, identically, by the /upload and /upload-folder responses.
## blobId is internal and never emitted.

import std/json
import ../../types

{.push raises: [].}

func storedFileJson*(f: StoredFile): string =
    ## File metadata with [JsonIgnore] BlobId omitted. camelCase to match ASP.NET's default output.
    $(%*{
        "id": f.id,
        "originalName": f.originalName,
        "contentType": f.contentType,
        "size": f.size,
        "uploadedAt": f.uploadedAt,
        "visibility": f.visibility,
    })

{.pop.}
