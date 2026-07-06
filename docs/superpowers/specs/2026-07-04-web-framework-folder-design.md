# Web framework folder — design

Date: 2026-07-04
Status: approved (Approach B)

## Goal

Extract the app-agnostic HTTP layer of `pastebin-api` into a dedicated
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

- `server.nim` — HTTP/1.1 server. Moved from `src/httpserver.nim`. Its
  low-level handler type is renamed `Handler` → `RequestHandler` to free the
  name `Handler` for the generic endpoint handler.
- `multipart.nim` — `multipart/form-data` parser. Moved verbatim from
  `src/multipart.nim`.
- `context.nim` — generic `Ctx*[E]` = `{ req: Request, ip: string,
  params: seq[string], cfg: E }`, `Handler*[E] = proc(ctx: Ctx[E]) {.nimcall.}`,
  `respondError`, and `errorJson` (the shared `{"error": …}` envelope, now the
  single definition). Re-exports `server`.
- `router.nim` — generic `Router*[P]`: path splitting, literal-beats-`{param}`
  matching, `add`/`match`. The payload type `P` is app-supplied, so the router
  knows nothing about handlers, admin, or upload flags.
- `middleware.nim` — the middleware mechanism: `Next`, `Middleware*[E] =
  proc(ctx: Ctx[E], next: Next)`, and `runChain` (onion-model chain runner).
  Middleware are plain closures so the app can build them per request.

### `src/framework.nim` — umbrella + entry point

Re-exports the four framework modules and defines `run(port, numThreads,
bodySpillThreshold, maxBodyBytes, networkLog, dispatch: RequestHandler)`. `run`
owns the per-request glue that used to live in main (optional NETLOG access
log, then hand-off to the app dispatch) and calls `server.serve`. App code
imports `framework` and never touches `framework/server` directly.

### `src/` app layer

- `endpoints/context.nim` — thin shim: `type Ctx* = framework/context.Ctx[AppConfig]`,
  `EndpointHandler*`, `rejectPasteGuard`, plus re-exports (server, config,
  jsonbuild, `errorJson`/`respondError`). Endpoint handler bodies are
  unchanged — they still `import ../context` and use `ctx.cfg`, `ctx.ip`,
  `ctx.params`, `ctx.req`.
- `endpoints/policies.nim` (new) — the cross-cutting policies as middleware:
  `rateLimit(isUpload): Middleware[AppConfig]` (the 3-tier limiter + uploads
  policy, acquiring on the way in and releasing concurrency on the way out) and
  `adminGate(): Middleware[AppConfig]` (fail-closed admin auth). Each factory
  returns a per-request closure that captures matched-route facts.
- `endpoints/dispatch.nim` (renamed from `endpoints/router.nim`) — the
  composition root: `RoutePayload = { handler, admin, upload }`, the ergonomic
  `get/post/delete` DSL, `RouteTable = Router[RoutePayload]`, `gRoutes`/`gCfg`,
  `initRoutes(table, cfg)`, `route()` (resolve IP → match → compose the
  `rateLimit` [outermost, so it wraps 404s too] + `adminGate` chain around the
  handler via `runChain`), and `handle()` — the `RequestHandler` passed to `run`.
- `src/main.nim` (renamed from `src/pastebin.nim`) — wires config → stores →
  `initRoutes(registerRoutes(), cfg)`, then calls `framework.run(..., handle)`.
- Import-only edits: `endpoints/routes.nim` (`import router` → `dispatch`,
  `registerRoutes(): RouteTable`), `clientip.nim` (`httpserver` →
  `framework/server`), `uploadFile.nim` + `uploadFolder.nim` (multipart path),
  `jsonbuild.nim` (drop its `errorJson` — framework now owns it).
- Build refs: `build.sh` + `Dockerfile` build `src/main.nim` (output binary
  still named `pastebin`); `pastebin.nimble` `bin = @["main"]`.

## Naming notes

- The generic context field is named `cfg` (type `E`) so existing endpoint
  bodies that read `ctx.cfg.*` need no change; the app instantiates
  `E = AppConfig`.
- `Router`/`Handler` name clashes are avoided by app-side aliases (`RouteTable`,
  `EndpointHandler`) and the `Handler` → `RequestHandler` rename in `server.nim`.

## Verification (done)

No test suite exists. `nim c src/main.nim` compiles clean, and a locally run
binary was smoke-tested across every route class: paste create/get/raw, recent
list, multipart file upload, 404, and the admin gate (401 on bad token → 2s
per-IP lockout → 200 with the token after cooldown).
