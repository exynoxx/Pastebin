## JSON bodies for the API's response records.
##
## `std/json`'s `%` already walks an object's fields and maps each Nim field name straight to a
## JSON key — and the Nim field names ARE the wire names — so every response builder is a one-liner
## over the domain type, and `%` over a seq gives the array form for free. Two shims are all that's
## needed on top: `BlobId` is a `distinct string`, which `%` can't render on its own, and it is
## internal, so the key is dropped again from the object `%` just built.
##
## `storedFileJson` is the file-metadata body returned by GET /api/files/{id} and, identically, by
## the /upload and /upload-folder responses.

import std/json
import ./types

func withoutBlobId(x: JsonNode): JsonNode

func `%`*(b: BlobId): JsonNode = %b.string
    ## Only so `%` over a Paste/StoredFile compiles — `withoutBlobId` drops the key right after.

func pasteJson*(p: Paste): string = $withoutBlobId(%p)
func storedFileJson*(f: StoredFile): string = $withoutBlobId(%f)
func pasteSummariesJson*(items: seq[PasteSummary]): string = $(%items)
func adminContentJson*(rows: seq[AdminContentRow]): string = $(%rows)
    ## Admin-only content list (carries fields no public builder emits: ownerIp, hasBlob).

func withoutBlobId(x: JsonNode): JsonNode =
    result = x
    result.delete("blobId")
