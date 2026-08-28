import std/[unittest, strutils]
import ../src/types
import ../src/writequeue

proc repeat(n: int): string = strutils.repeat('x', n)

proc paste(id: string): Paste =
  Paste(id: id, title: id, size: 0, isTruncated: false,
        createdAt: 0, visibility: Public, blobId: BlobId(""), content: "")

suite "writequeue (no persister thread)":
  test "an enqueued paste is pending with its full content":
    resetForTest(1000)
    check enqueue(paste("a"), "FULLCONTENT", "ip1")
    check pending("a").content == "FULLCONTENT"

  test "unknown id is not pending":
    resetForTest(1000)
    check pending("nope") == nil

  test "over budget is refused — unwritten content can't be dropped":
    resetForTest(100)
    check enqueue(paste("a"), repeat(60), "ip1")
    check not enqueue(paste("b"), repeat(60), "ip1")
    check pending("b") == nil

  test "cancel frees the budget again":
    resetForTest(100)
    check enqueue(paste("a"), repeat(60), "ip1")
    check cancel("a")
    check pending("a") == nil
    check enqueue(paste("b"), repeat(60), "ip1")

  test "cancelling twice reports false the second time (mid-write rollback signal)":
    resetForTest(100)
    check enqueue(paste("a"), repeat(10), "ip1")
    check cancel("a")
    check not cancel("a")
