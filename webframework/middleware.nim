## The middleware mechanism: an onion-model chain runner over the generic request context.
##
## App-agnostic — the framework knows *how* to compose middleware, not *what* any middleware does.
## A `Middleware[E]` wraps the rest of the chain: it does work, decides whether to proceed by
## calling `next()`, and can run cleanup afterwards (the classic before/after "onion"). Not calling
## `next()` short-circuits the request (e.g. a rate limiter that already responded 503).
##
## Middleware are plain closures, so the app can build them per request and capture matched-route
## facts (see the app's policies + dispatch). They run synchronously on the server worker threads.

import context

type
    Next* = proc() {.gcsafe.}
        ## Advances to the next middleware, or the final handler when the chain is exhausted.

    Middleware*[E] = proc(ctx: Ctx[E], next: Next) {.gcsafe.}
        ## Wraps the remainder of the chain. Call `next()` to proceed; skip it to short-circuit.

proc runChain*[E](ctx: Ctx[E], chain: seq[Middleware[E]], final: Next) =
    ## Run `chain` in order, each wrapping the next, with `final` (the endpoint call) at the centre.
    ## Builds the `next` closures lazily so a middleware that short-circuits never advances the rest.
    if chain.len == 0:
        final()          # no middleware => skip building the closure ladder entirely
        return
    proc at(i: int): Next =
        result = proc() {.gcsafe.} =
            # `at` recurses to build the next link; the cast affirms the whole chain is gcsafe
            # (middleware, `final`, and `at` itself all carry the {.gcsafe.} contract).
            {.cast(gcsafe).}:
                if i >= chain.len: final()
                else: chain[i](ctx, at(i + 1))
    at(0)()
