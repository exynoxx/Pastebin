import std/[unittest, options, strutils]
import ../src/types
import ../src/pastecache

proc repeat(n: int): string = strutils.repeat('x', n)   # an n-byte string, for explicit budget math

proc paste(id, content: string): Paste =
  Paste(id: id, title: id, size: content.len.int64, isTruncated: false,
        createdAt: 0, visibility: Public, blobId: BlobId(""), content: content)

suite "pastecache (read cache)":
  test "put then get":
    initPasteCache(1000)
    put(paste("a", "hello"))
    check get("a").get.content == "hello"

  test "unknown id misses":
    initPasteCache(1000)
    check get("nope").isNone

  test "a paste larger than the whole budget is not cached":
    initPasteCache(4)
    put(paste("a", "hello"))
    check get("a").isNone

  test "evicts in LRU order to make room":
    initPasteCache(100)
    put(paste("a", repeat(40)))
    put(paste("b", repeat(40)))
    put(paste("c", repeat(40)))     # needs 40 of the 20 free bytes -> evicts a
    check get("a").isNone
    check get("b").isSome
    check get("c").isSome

  test "a read moves an entry to MRU":
    initPasteCache(100)
    put(paste("a", repeat(40)))
    put(paste("b", repeat(40)))
    discard get("a")                # a is now MRU; b is LRU
    put(paste("c", repeat(40)))
    check get("b").isNone
    check get("a").isSome

  test "re-put replaces without double-counting bytes":
    initPasteCache(100)
    put(paste("a", repeat(40)))
    put(paste("a", repeat(40)))
    put(paste("b", repeat(60)))     # only fits if a is counted once
    check get("a").isSome
    check get("b").isSome

  test "remove evicts":
    initPasteCache(100)
    put(paste("a", repeat(40)))
    remove("a")
    check get("a").isNone
