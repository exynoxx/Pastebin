## Application errors carried up to the route layer.
## Services raise them; the route layer maps each to an HTTP status with the message as {"error": ...}:
##   PayloadTooLargeError -> 413 payload too large
##   CacheFullError       -> 429 cache full (server at capacity)

type
    PayloadTooLargeError* = object of CatchableError
    CacheFullError* = object of CatchableError
