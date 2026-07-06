## Unique temp-file paths without a PRNG.
##
## Math.random-style entropy isn't available here, so a path is built from process id +
## monotonic-clock ticks + a process-local incrementing counter. Even under a concurrent-request
## race on the counter the monotonic ticks differ, so a collision isn't realistically possible.
## Shared by the body-spill path (httpserver) and the multipart part writer so the two don't each
## carry a near-identical copy.

import std/[os, monotimes, strformat]

var gTempSeq: int  ## process-local, monotonically increasing — never repeats within a run.

proc uniqueTempPath*(prefix: string): string =
    inc gTempSeq
    getTempDir() / (&"{prefix}-{getCurrentProcessId()}-{getMonoTime().ticks}-{gTempSeq}.tmp")
