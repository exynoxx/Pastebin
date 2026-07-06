## The route-registration facade. `RouteTable[E]` holds the routes, the global middleware chain,
## and an optional custom 404, generic over `E` (the app-supplied state every handler receives via
## `Ctx[E]`). Build it once at startup with the verb procs and `use`, then hand it to `run`.

import router, context, middleware

export Handler        # so an app can name Handler[E] without importing context directly

type
    RouteTable*[E] = object
        router*: Router[Handler[E]]
        global*: seq[Middleware[E]]     ## runs on every request, in registration order
        notFound*: Handler[E]           ## nil => framework default 404

# One proc per verb so call sites read as a table: result.get(...), result.post(...).

proc get*[E](t: var RouteTable[E], path: string, handler: Handler[E]) =
    t.router.add("GET", path, handler)

proc post*[E](t: var RouteTable[E], path: string, handler: Handler[E]) =
    t.router.add("POST", path, handler)

proc delete*[E](t: var RouteTable[E], path: string, handler: Handler[E]) =
    t.router.add("DELETE", path, handler)

proc put*[E](t: var RouteTable[E], path: string, handler: Handler[E]) =
    t.router.add("PUT", path, handler)

proc patch*[E](t: var RouteTable[E], path: string, handler: Handler[E]) =
    t.router.add("PATCH", path, handler)

# ---- global middleware + 404 ------------------------------------------------

proc use*[E](t: var RouteTable[E], m: Middleware[E]) =
    ## Register a global middleware. The first `use` is the outermost layer of the onion.
    t.global.add m

proc onNotFound*[E](t: var RouteTable[E], handler: Handler[E]) =
    ## Override the default JSON 404 (still wrapped by the global chain).
    t.notFound = handler
