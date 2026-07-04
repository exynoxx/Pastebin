## Application error carried up to the route layer.
## Mirrors the .NET pattern where services throw InvalidOperationException and the controllers
## map it to HTTP 413 with the exception message as {"error": ...}.

type
    PayloadTooLargeError* = object of CatchableError ## -> HTTP 413
