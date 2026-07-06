## Shared JSON serialization: the `serialize` macro plus the derived response builders.
##
## `serialize(T, omit = [field, ...])` reads T's object fields and emits
## `func <t>Json*(x: T): string`, mapping each field to a camelCase key (Nim field names
## already match ASP.NET's default camelCase output). Fields in `omit` are dropped — used
## to keep internal columns like `blobId` out of JSON. Single-object only: array responses
## (and per-field hooks like ""->null) are shaped by hand in their slice.
##
## `storedFileJson` is the file-metadata body returned by GET /api/files/{id} and,
## identically, by the /upload and /upload-folder responses. blobId is internal.

import std/[json, macros, strutils]
import ./types

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
    let funcName = toLowerAscii(tn[0]) & tn[1 .. ^1] & "Json"
    let body = newStmtList(newCall(ident("$"), prefix(tableConstr, "%*")))
    result = newProc(
        name = nnkPostfix.newTree(ident("*"), ident(funcName)),
        params = @[ident("string"), newIdentDefs(ident("x"), objSym)],
        body = body,
        procType = nnkFuncDef)

{.push raises: [].}

# File metadata with [JsonIgnore] BlobId omitted. camelCase to match ASP.NET's default output.
serialize(StoredFile, omit = [blobId])

{.pop.}
