## Shared JSON serialization: the `serialize` macro plus the derived response builders.
##
## `serialize(T, omit = [field, ...])` reads T's object fields and emits two funcs:
##   `func <t>Node*(x: T): JsonNode`  — the JSON object (fields in `omit` dropped)
##   `func <t>Json*(x: T): string`    — `$<t>Node(x)`
## Field names map straight to JSON keys (the Nim field names are already the wire names).
## `omit` keeps internal columns like `blobId` out of JSON. The `Node` builder lets array
## responses assemble a JArray from the same field definition instead of repeating it by hand.
##
## `storedFileJson` is the file-metadata body returned by GET /api/files/{id} and,
## identically, by the /upload and /upload-folder responses. blobId is internal.

import std/[json, macros, strutils]
import ./types

# Render Visibility as its wire string ("public"/"private") wherever the serialize macro emits a
# `%*` over an object with a visibility field. Defined here so every serialize(...) call site sees it.
func `%`*(v: Visibility): JsonNode = %($v)

macro serialize*(T: typedesc, omit: untyped = []): untyped =
    omit.expectKind(nnkBracket)
    var omitted: seq[string]
    for o in omit: omitted.add(o.strVal)

    # T is a typedesc; unwrap to the object's record list.
    let objSym = T.getTypeImpl[1]
    let recList = objSym.getTypeImpl[2]
    recList.expectKind(nnkRecList)

    var tableConstr = nnkTableConstr.newTree()
    for defn in recList:
        defn.expectKind(nnkIdentDefs)
        # a field def is `name*: type` (postfix) or `name: type`; keep every ident before the type.
        for i in 0 ..< defn.len - 2:
            let raw = defn[i]
            let fieldName = (if raw.kind == nnkPostfix: raw[1] else: raw).strVal
            if fieldName in omitted: continue
            tableConstr.add(nnkExprColonExpr.newTree(
                newLit(fieldName), newDotExpr(ident("x"), ident(fieldName))))

    let tn = objSym.strVal
    let base = toLowerAscii(tn[0]) & tn[1 .. ^1]
    let nodeName = base & "Node"
    let jsonName = base & "Json"

    # func <base>Node*(x: T): JsonNode = %*{ ... }
    let nodeProc = newProc(
        name = nnkPostfix.newTree(ident("*"), ident(nodeName)),
        params = @[ident("JsonNode"), newIdentDefs(ident("x"), objSym)],
        body = newStmtList(prefix(tableConstr, "%*")),
        procType = nnkFuncDef)

    # func <base>Json*(x: T): string = $ <base>Node(x)
    let jsonProc = newProc(
        name = nnkPostfix.newTree(ident("*"), ident(jsonName)),
        params = @[ident("string"), newIdentDefs(ident("x"), objSym)],
        body = newStmtList(newCall(ident("$"), newCall(ident(nodeName), ident("x")))),
        procType = nnkFuncDef)

    result = newStmtList(nodeProc, jsonProc)

{.push raises: [].}

# File metadata with BlobId omitted (internal).
serialize(StoredFile, omit = [blobId])

{.pop.}
