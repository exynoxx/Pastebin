# Nim house-style guide — `pastebin-api-nim/`

House style for the Nim backend at `pastebin-api-nim/` (18 modules, ~2,080 LOC in `src/`) — the
drop-in replacement for the .NET `pastebin-api/`. Two hard constraints shape everything below:

1. **Memory.** This runs on a **Raspberry Pi 3B** (~900 MB RAM) under a **250 MB RSS cap**. Prettiness
   yields to memory: no sugar that measurably allocates in a per-request hot path.
2. **.NET parity.** The Nim backend must speak a **byte-identical HTTP/JSON contract** and share the
   **same SQLite schema and blob layout** as the C# original, so it reads the live production DB with
   no migration. That fixes external names (`created_at`, `MAX_REQUEST_BYTES`, JSON camelCase) — they
   are contracts, not style choices.

This guide is **aspirational**: it codifies the good conventions the code already follows *and*
prescribes the idiomatic-Nim upgrades the code hasn't adopted yet. Each upgrade shows a real
before→after drawn from the modules. Applying them to existing modules is follow-up work — treat the
guide as the target every new or touched module should move toward.

---

## 1. Formatting & layout

- **Indent 4 spaces.** The majority of modules already do; `httpserver.nim` is the lone 2-space
  outlier and should be reflowed when next touched. Pick 4 and never mix within a file.
- **Import grouping — three blocks, stdlib → third-party → local:**

  ```nim
  import std/[json, strutils, options, os]           # stdlib, bracket-grouped
  import db_connector/db_sqlite                       # third-party (db_connector, zippy)
  import httpserver, config, clientip, jsonbuild      # local modules, plain names
  ```

  Use the `std/[...]` bracket form for multiple stdlib imports (`router.nim:4`, `db.nim:14`); the
  plain `std/x` form is fine for a single one (`clientip.nim:13` `import std/strutils`).
- **`*` export postfix on public API only.** Already consistent — `resolveClientIp*`, `Request*`,
  `httpMethod*` are exported; helpers like `generateId`, `deriveTitle`, `respondError` are not.

---

## 2. Naming

Already strong — codify it:

| Kind | Convention | Examples |
|---|---|---|
| Procs, vars | `camelCase` | `resolveClientIp`, `sumUsageForOwner`, `winStart` |
| Types, consts | `PascalCase` | `AppConfig`, `DownloadData`, `IdAlphabet`, `WindowSec` |
| Module-global vars | `g`-prefix | `gRlLock`, `gPerIp`, `gConcurrent`, `gListener` |
| Thread-locals | `tl`-prefix | `tlConn`, `tlOpen` (`db.nim:23-24`) |

**snake_case appears only in external contracts** — SQL column names (`owner_ip`, `created_at`) and
env-var keys (`MAX_REQUEST_BYTES`) — **never** in Nim identifiers. That boundary is the rule, not an
accident; keep it crisp.

---

## 3. `func` for purity, `{.raises.}` for the contract

The code uses `proc` for everything, including provably pure helpers. **Adopt `func` for
side-effect-free routines** — it documents purity and lets the compiler enforce it.

Pure targets: all of `jsonbuild.nim`, `timeutil.isoToUniversal`, `files.normalizeVisibility` /
`zipEntryName`, and `pastes.deriveTitle` / `buildPreview`.

```nim
# before — pastes.nim:15
proc deriveTitle(content: string, maxChars: int): string =

# after
func deriveTitle(content: string, maxChars: int): string =
```

**Annotate the exception contract with `{.raises.}`** where it's already understood. Only
`PayloadTooLargeError` and broad `CatchableError` cross the service boundary (see §4), so make it
explicit and let the compiler hold the line:

```nim
proc createPaste*(cfg: AppConfig, title, content, visibilityIn, ownerIp: string): Paste
    {.raises: [PayloadTooLargeError, DbError, IOError].} = ...
```

For a whole pure module, hoist it to the top with a push region:

```nim
{.push raises: [].}   # jsonbuild.nim — nothing here may throw
# ... all builders ...
{.pop.}
```

---

## 4. Error handling — three pillars, keep them

The existing model is good and idiomatic; standardize on it explicitly:

1. **Exceptions for size/quota failures.** Raise `PayloadTooLargeError` (the only custom error,
   `apperrors.nim`) via `newException`:

   ```nim
   # quota.nim:12
   raise newException(PayloadTooLargeError,
       "Storage quota exceeded ...")
   ```

2. **`Option[T]` for not-found lookups** — never exceptions for "missing". Return `Option`, consume
   with `isNone` / `.get`:

   ```nim
   # pastes.nim:65 + router.nim:56-59
   proc getPaste*(id: string): Option[Paste] = selectPaste(id)

   let p = getPaste(id)
   if p.isNone: respondError(req, 404, "Paste not found")
   else: req.respond(200, pasteJson(p.get))
   ```

3. **`bool` for delete-success** (`deletePaste*`, `deleteFileRow*`).

**The catch ladder** at the route boundary is: typed error → `except CatchableError` (never a bare
`except`) → `finally` for cleanup. This is the canonical shape (`router.nim:107-115`):

```nim
try:
    let r = uploadFile(cfg, fileEntry.get, ip, visibility)
    req.respond(200, fileUploadResultJson(r))
except PayloadTooLargeError as e:
    respondError(req, 413, e.msg)
except CatchableError as e:
    respondError(req, 500, "Upload failed: " & e.msg)
finally:
    cleanupEntries(entries)
```

`discard` on best-effort cleanup is sanctioned — but always with a comment saying why
(`pastes.nim:81` `discard deleteBlob(...)`, `httpserver.nim:124` `except CatchableError: discard # peer disconnected`).

---

## 5. Strings — prefer `strformat` over `&`-concatenation

The single most consistent (and least pretty) fact about the codebase: **every message is built with
the `&` operator + `$` stringify.** Adopt `std/strformat` — `&"..."` for interpolation with escapes,
`fmt"..."` for raw. It reads far cleaner for multi-part messages:

```nim
# before — quota.nim:13-14
raise newException(PayloadTooLargeError,
    "Storage quota exceeded for your address (" & $quotaMb & " MB). " &
    "Delete old pastes or try later.")

# after
import std/strformat
raise newException(PayloadTooLargeError,
    &"Storage quota exceeded for your address ({quotaMb} MB). Delete old pastes or try later.")
```

```nim
# before — pastes.nim:43-45
"Paste size exceeds the maximum allowed size of " &
    $(cfg.maxPasteBytes div (1024 * 1024)) & "MB"

# after
&"Paste size exceeds the maximum allowed size of {cfg.maxPasteBytes div (1024*1024)}MB"
```

**Never hand-escape JSON string literals.** Replace escaped-quote constants with the existing
`errorJson` builder (`jsonbuild.nim:7`) or `%*`:

```nim
# before — router.nim:8
const BusyBody = "{\"error\":\"Server busy or rate limit exceeded. Please retry shortly.\"}"

# after
const BusyBody = errorJson("Server busy or rate limit exceeded. Please retry shortly.")
```

Keep `sql"""..."""` raw literals for queries exactly as they are (`db.nim`) — that's the right tool.

---

## 6. Collections — `collect` / `mapIt` over manual `for … add`

Accumulation loops (`var acc; for … acc.add`) should become `sequtils`/`sugar` comprehensions where
it reads cleaner:

```nim
# before — jsonbuild.nim:23-34
proc summariesJson*(items: seq[PasteSummary]): string =
    var arr = newJArray()
    for s in items:
        arr.add(%*{
            "id": s.id, "title": s.title, "size": s.size,
            "createdAt": s.createdAt, "kind": s.kind,
            "contentType": (if s.contentType.len == 0: newJNull() else: %s.contentType),
        })
    $arr

# after
import std/[json, sugar]
proc summariesJson*(items: seq[PasteSummary]): string =
    $(collect(newJArray):
        for s in items:
            %*{
                "id": s.id, "title": s.title, "size": s.size,
                "createdAt": s.createdAt, "kind": s.kind,
                "contentType": (if s.contentType.len == 0: newJNull() else: %s.contentType),
            })
```

The same applies to the row→seq loops in `db.nim:159-164`. For simple transforms, `mapIt` beats a
loop: `items.mapIt(it.id)`.

> **Caveat — memory beats prettiness.** In per-request hot paths, `collect`/`mapIt` allocate an
> intermediate; if profiling shows RSS pressure, keep the explicit loop and add a comment. The
> 250 MB cap wins. Reach for comprehensions in cold/setup paths first.

---

## 7. Types

- **`object` by default; `ref object` only for lock-guarded shared mutable state** — e.g.
  `SlidingState` (`ratelimit.nim:18`), `Request*` (`httpserver.nim:21`). Don't make domain records
  `ref` without a reason.
- **Named-field construction, always:** `Paste(id: id, title: ttl, size: byteCount, ...)`
  (`pastes.nim:49`). Never positional.
- **`##` doc-comments on fields** — already done well in `types.nim` / `config.nim`; keep it.

**Adopt case-object variants for tagged unions.** `DownloadData` currently hand-rolls one with a
`bool` flag plus two mutually-exclusive fields — the compiler can't stop you reading the wrong one:

```nim
# before — types.nim:46-52
DownloadData* = object
    fromBlob*: bool
    blobPath*: string      ## valid when fromBlob
    inlineData*: string    ## valid when not fromBlob
    contentType*: string
    fileName*: string

# after
DownloadKind* = enum dkBlob, dkInline
DownloadData* = object
    contentType*: string
    fileName*: string
    case kind*: DownloadKind
    of dkBlob:   blobPath*: string
    of dkInline: inlineData*: string
```

Construction stays named-field (`DownloadData(kind: dkBlob, blobPath: ..., ...)`), and consumers
switch on `case dd.kind` instead of `if dd.fromBlob` (`pastes.nim:89-92`, `router.nim:67-70`).

**String-typed enumerations are a sanctioned parity exception.** `visibility` ("public"/"private"),
`kind` ("paste"/"file"), and HTTP method strings are plain `string`, not Nim enums — deliberately, so
they map 1:1 to the DB and JSON contract. This is intentional; don't "fix" it into enums.

---

## 8. Control flow

- **`if`/`case` as expressions** — already idiomatic, keep it (`clientip.nim:20`, the `reason(code)`
  `case` expression in `httpserver.nim:44-56`).
- **One return style per proc.** The codebase currently mixes implicit-`result` accumulation, explicit
  `result = …`, and bare trailing expression *within single procs* — standardize:
  - **Builders that accumulate** → implicit `result` (`result.add …`), no final `return`.
  - **One-liners** → bare trailing expression (`clientip.nim:31` `"unknown"`).
  - **Guard / error paths** → early `return`.

  `config.getLong` (`config.nim:46-51`) shows the smell — it mixes `return fallback` with
  `result = parseBiggestInt(...)`. Prefer one:

  ```nim
  # after
  func getLong(key: string, fallback: int64): int64 =
      let v = getEnv(key)
      if v.len == 0: return fallback
      try: parseBiggestInt(v.strip())
      except ValueError: fallback
  ```

- **`.add` call style: pick paren-less** command form (`result.add frac`, `staleIp.add ip`) and use it
  everywhere, including `jsonbuild` (currently `arr.add(...)`). One style per codebase.

---

## 9. Build config

Keep the clean split:

- **`nim.cfg`** — compiler/runtime flags: `--mm:orc -d:useMalloc --threads:on -d:ssl`. `orc` +
  `useMalloc` are the low-RSS choices (deterministic cycle collection, libc allocator returns pages to
  the OS) — tie any flag change back to the 250 MB cap.
- **`pastebin.nimble`** — dependencies + `bin`/`srcDir` only.

Runtime tuning lives in `nim.cfg`; package metadata lives in the nimble file. Don't cross them.

---

## 10. Where plainness wins

The two constraints at the top override every rule above:

- **RSS cap** → no comprehension/`fmt` allocation in a measured per-request hot path. Explicit loop +
  comment beats a pretty one-liner that costs memory.
- **.NET parity** → external identifiers stay snake_case; JSON stays camelCase; `sql` literals stay
  literal. Style stops at the contract boundary.

When prettiness and either constraint collide, the constraint wins — and a one-line comment should say
so, so the plainness reads as deliberate.
