## Application error carried up to the route layer.
## Services raise it; the route layer maps it to HTTP 413 with the message as {"error": ...}.

type
    PayloadTooLargeError* = object of CatchableError
