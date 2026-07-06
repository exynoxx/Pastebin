# Web framework extraction — design

**Date:** 2026-07-06

## Goal

Move all *generic* HTTP-framework logic out of the app (`endpoints/dispatch.nim`,
`endpoints/context.nim`) and into `webframework/`, so the framework — not app code — owns the
routing DSL, the per-request dispatch flow, and the `Ctx`/`Handler` types. The app is left with
only its route table (`routes.nim`, already the ideal interface) and its handlers. The framework
passes an app-supplied `userData` value through to every handler (here `AppConfig`; in another app
it might be a DI container).

## Constraint that shapes everything

`RequestHandler = proc(req: Request) {.nimcall, gcsafe.}` (webframework/httpserver.nim). A nimcall
handler cannot capture state, and Nim has no module-level global of a generic type. This is *why*
`dispatch.nim` exists in the app today: its globals (`gRoutes: Router[RoutePayload]`,
`gCfg: AppConfig`) are concrete. To delete `dispatch.nim`, the framework must generate that concrete
glue at the call site — hence `serve` becomes a template (§3).

## 1. File plan

- **Delete** `endpoints/dispatch.nim`, `endpoints/context.nim`.
- **New** `webframework/routing.nim` — the `get/post/delete` DSL + `{param}` template overloads,
  generic over `E`.
- **Rework** `webframework/dispatcher.nim` — generic `dispatchRequest[E]`; owns the default
  `notFound` and the `global ++ route` middleware composition.
- **Rework** `webframework/server.nim` — `serve` becomes a template.
- **Edit** `webframework/context.nim` — rename field `cfg` → `userData`.
- **Rewrite** `ratelimit.nim` — global `overloadGuard()` middleware + per-route `uploadThrottle()`.
- **Edit** `types.nim` — add the `Ctx = Ctx[AppConfig]` / `Handler` alias; re-export framework
  context + config.
- **Unchanged** `router.nim`, `middleware.nim`, `httpserver.nim`, `macros.nim`, `multipart.nim`,
  `tmpfile.nim`.

## 2. Routing DSL (framework, generic)

```nim
type
  RouteEntry[E] = object
    handler: Handler[E]
    middleware: seq[Middleware[E]]
  Routes*[E] = Router[RouteEntry[E]]
```

`get/post/delete` procs + the `{param}`-binding template overloads move from `dispatch.nim` into
`routing.nim`, generic over `E`, each taking optional `middleware: seq[Middleware[E]] = @[]`.
`routes.nim` keeps reading the same; the old `upload = true` flag becomes
`middleware = @[uploadThrottle()]`. `registerRoutes` returns `Routes[AppConfig]`.

## 3. `serve` as a template

`serve` expands in `main.nim`, injecting the write-once concrete globals (routes, userData,
resolveIp, global middleware, netlog flag) + the nimcall trampoline, then calling `listenAndServe`.
The per-request flow itself is a plain generic proc `dispatchRequest[E]` in `dispatcher.nim`:
resolve ip → match → build `Ctx[E]` → compose `globalMiddleware ++ routeEntry.middleware` around
handler-or-`notFound` → `runChain`. `initRoutes` folds into `serve`.

Call site:

```nim
serve(
  port = cfg.port, numThreads = cfg.workerThreads,
  bodySpillThreshold = cfg.inlinePasteMaxBytes, maxBodyBytes = cfg.maxRequestBytes,
  networkLog = cfg.networkLog,
  routes = registerRoutes(), userData = cfg,
  resolveIp = resolveClientIp,
  middleware = @[overloadGuard()])
```

**Rejected alternative:** type-erase `userData` to `RootRef` (framework stays non-generic). Forces
`AppConfig` to a `ref` and casts in every handler; loses typed `ctx.userData.x`.

## 4. Ctx + handler alias

- `context.nim`: `cfg` → `userData`. `Ctx[E]`, `Handler[E]`, `errorJson`, `respondError`,
  `fetchOr404`, `parseJsonBodyOr400` stay framework-side.
- `types.nim`: `import config, webframework/context`; `type Ctx* = context.Ctx[AppConfig]`
  (+ `Handler`); re-export `context` + `config`. Handlers drop `import ../context` and rely on
  their existing `types` import; `proc(ctx: Ctx)` is unchanged.
- **Known tradeoff:** `types.nim` (innermost domain records, currently import-free) now pulls in the
  framework, so `db.nim`/`ntfy.nim`/`json.nim` transitively import it. Compiles, no cycle; mild onion
  inversion. Accepted.

## 5. Rate-limit rewrite (phase 2)

- **`overloadGuard()` — global, outermost.** Atomic per-IP window + global window + concurrency cap
  (today's `tryAcquire` minus the uploads tier). Still covers 404s. Preserves the
  concurrency-vs-window atomic commit.
- **`uploadThrottle()` — per-route** on the two upload routes. Stricter per-IP uploads fixed window
  (10/min), inner middleware.
- **`checkPasteCreate`/`rejectPasteLimit`** stay called directly in the paste handlers.

**Semantic change:** an upload rejected by the 10/min cap now also consumes one general per-IP slot
(previously one atomic `tryAcquire` rejected before committing anything). Negligible for a
single-user Pi pastebin; accepted in favour of the clean split.

## Order of work

Build and verify §1–4 (framework extraction) first with `nim check` + e2e; then §5 (rate-limit
rewrite) against the new middleware surface.
