# RouteTable facade — design

Date: 2026-07-06

## Goal

Finish the in-house Nim web framework by adding the ergonomic top layer its
target interface implies. Everything underneath already exists and stays as-is:
the raw threaded HTTP server (`httpserver.nim`), the generic router
(`router.nim`), the per-request context (`context.nim`), the onion middleware
mechanism (`middleware.nim`), and the generic dispatcher (`dispatcher.nim`).

The public consumer interface is:

```nim
proc registerRoutes(): RouteTable[AppState] =
  result.get(   "/api/pastes",       handleRecentPastes)
  result.post(  "/api/pastes",       handleCreatePaste)
  result.get(   "/api/pastes/{id}",  handleGetPaste)
  ...

run(registerRoutes(), AppState(...), ServerConfig(port: 8080, ...))
```

## Decisions (from brainstorming)

- **Keep the raw threaded server.** "Based on asynchttpserver" is the conceptual
  model (same `Request`/`respond` shape), not a literal dependency. The existing
  server satisfies two hard requirements asynchttpserver can't: streaming large
  request bodies to a temp file, and Range-aware file download streaming.
  `httpserver.nim` is **untouched**.
- **`upload=true` is app-specific, not a framework concept.** It is neither
  framework middleware nor a route flag — it is just what the handler does
  (`ctx.req.bodyFile()` + multipart parse). No `upload` sugar in the framework.
- **Middleware is global only.** Registered once on the table via `use(...)`,
  runs on every request in registration order. No per-route middleware.
- **Deliverable: library + one runnable demo** proving the interface compiles and
  serves. Not the full pastebin app.

## Components

### `routetable.nim` (new) — `RouteTable[E]`

Generic over `E`, the app-supplied user/state structure ("main-supplied user
structure", C# minimal-API style). Route payload is the handler itself.

```nim
type RouteTable*[E] = object
  router: Router[Handler[E]]
  global: seq[Middleware[E]]     # every request, in registration order
  notFound: Handler[E]           # optional custom 404 (default: JSON 404)

proc get*[E]/post*[E]/delete*[E]/put*[E]/patch*[E](
    t: var RouteTable[E], path: string, handler: Handler[E])
proc use*[E](t: var RouteTable[E], m: Middleware[E])
proc onNotFound*[E](t: var RouteTable[E], h: Handler[E])
```

### `server.nim` — `run*[E]` + `ServerConfig`

The single call an app makes. Bridges the `RouteTable[E]` onto the existing
`serve`/`dispatchRequest`, respecting the raw server's `nimcall`-not-closure
handler constraint via per-instantiation `{.global.}` vars and a non-capturing
`nimcall` entry proc.

```nim
type ServerConfig* = object
  port*, numThreads*, bodySpillThreshold*: int
  maxBodyBytes*: int64
  networkLog*: bool

proc defaultConfig*(): ServerConfig            # sane defaults
proc run*[E](routes: RouteTable[E], state: E, config = defaultConfig(),
             resolveIp: ResolveIp = defaultResolveIp)
```

`defaultResolveIp` reads `X-Forwarded-For` (first token) then falls back to
`remoteAddress` — correct behind nginx.

Dispatch wiring: `chainFor` always returns the global chain (matched or not);
`handlerFor` returns the matched handler, else `notFound`.

### `context.nim` — additive `Ctx` request-info helpers

Thin conveniences so handlers read request info without reaching through `.req`:
`header`, `queryParam`, `httpMethod`, `path`, `remoteAddress`, `origin`.
Nothing removed.

### `examples/pastebin_routes.nim` (new) — demo

An `AppState` struct, a few named handlers, a `requireAdmin` global middleware, a
`registerRoutes()` returning `RouteTable[AppState]`, and a `run(...)` call.

## Verification

Compile framework + demo with `nim c`, start it, and `curl` a GET, an `{id}`
param route, and a 404 to confirm real end-to-end request/response behavior.
