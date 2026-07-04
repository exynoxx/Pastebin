# Web framework folder — design

Date: 2026-07-04
Status: approved (Approach B)

## Goal

Extract the app-agnostic HTTP layer of `pastebin-api-nim` into a dedicated
`src/framework/` folder with **zero app imports**, separating the reusable web
*mechanism* from this app's *security policies*. The app depends on the
framework, never the reverse.

## Approach

**B — Framework = mechanism, app = composition root.** The framework provides
the HTTP server, the multipart parser, a generic URL router, and a generic
request-context type. The app keeps its specific policies (client-IP
resolution, 3-tier rate limiting, admin-token gate, paste guard) in a thin
dispatch module that wires them around the matched handler.

Rejected: an onion `proc(ctx, next)` middleware framework (Approach A) — it
invents an abstraction this single app doesn't need, and the concurrency
`finally` release fights the `next`-closure model under `--threads:on`/gcsafe.

## Layout

### `src/framework/` — std-only, zero app imports

- `server.nim` — HTTP/1.1 server. Moved verbatim from `src/httpserver.nim`.
- `multipart.nim` — `multipart/form-data` parser. Moved verbatim from
  `src/multipart.nim`.
- `context.nim` — generic `Ctx*[E]` = `{ req: Request, ip: string,
  params: seq[string], cfg: E }`, `Handler*[E] = proc(ctx: Ctx[E]) {.nimcall.}`,
  `respondError`, and `errorJson` (the shared `{"error": …}` envelope).
  Re-exports `server`.
- `router.nim` — generic `Router*[P]`: path splitting, literal-beats-`{param}`
  matching, `add`/`match`. The payload type `P` is app-supplied, so the router
  knows nothing about handlers, admin, or upload flags.

### `src/` app layer

- `endpoints/context.nim` — thin shim: `type Ctx* = framework/context.Ctx[AppConfig]`,
  `EndpointHandler*`, `rejectPasteGuard`, plus re-exports. Endpoint handler
  bodies are unchanged — they still `import ../context` and use `ctx.cfg`,
  `ctx.ip`, `ctx.params`, `ctx.req`.
- `endpoints/dispatch.nim` (renamed from `endpoints/router.nim`) — the
  composition root: `RoutePayload = { handler, admin, upload }`, the ergonomic
  `get/post/delete` DSL, `gRoutes`, `initRoutes`, `route()` (client-IP +
  rate-limit + admin-gate + concurrency wiring), and `passAdminGate`.
- Import-only edits: `endpoints/routes.nim` (`import router` → `dispatch`, call
  sites unchanged), `clientip.nim`, `pastebin.nim`,
  `endpoints/files/uploadFile.nim` + `uploadFolder.nim` (multipart path),
  `jsonbuild.nim` (drop its `errorJson`, re-export the framework one to stay DRY).

## Naming note

The generic context field is named `cfg` (type `E`) so existing endpoint bodies
that read `ctx.cfg.*` need no change; the app instantiates `E = AppConfig`.

## Verification

No test suite exists. `nim c src/pastebin.nim` must compile clean, then a smoke
request per route class (paste create/get, file upload, admin list) against a
locally run binary.
