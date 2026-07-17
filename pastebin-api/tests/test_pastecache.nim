import std/[unittest, options, strutils]
import ../src/types
import ../src/pastecache

proc repeat(n: int): string = strutils.repeat('x', n)   # an n-byte string, for explicit budget math

# Build an inline display Paste + its full content (fullContent == content for inline).
proc inlinePaste(id, content: string): Paste =
  Paste(id: id, title: id, size: content.len.int64, isTruncated: false,
        createdAt: 0, visibility: Public, blobId: BlobId(""), content: content)

# Build a large display Paste (content = preview) paired with its full content.
proc largePaste(id, preview: string): Paste =
  Paste(id: id, title: id, size: 999999, isTruncated: true,
        createdAt: 0, visibility: Public, blobId: BlobId(""), content: preview)

suite "pastecache":
  test "admit under budget stores full content":
    resetForTest(1000)
    check admit(inlinePaste("a", "hello"), "hello", "ip1")
    let got = getDisplayPaste("a")
    check got.isSome
    check got.get.content == "hello"

  test "single paste larger than budget is refused":
    resetForTest(4)
    check not admit(inlinePaste("a", "hello"), "hello", "ip1")
    check getDisplayPaste("a").isNone

  test "dirty entries are never evicted -> refusal when only dirty bytes remain":
    resetForTest(100)
    check admit(inlinePaste("a", repeat(30)), repeat(30), "ip1")
    check admit(inlinePaste("b", repeat(30)), repeat(30), "ip1")
    check admit(inlinePaste("c", repeat(30)), repeat(30), "ip1")
    # 90 dirty bytes used; a 30-byte paste needs eviction but nothing is clean.
    check not admit(inlinePaste("d", repeat(30)), repeat(30), "ip1")

  test "clean entries evicted in LRU order":
    resetForTest(100)
    check admit(inlinePaste("a", repeat(40)), repeat(40), "ip1")
    check markPersisted("a", BlobId(""))
    check admit(inlinePaste("b", repeat(40)), repeat(40), "ip1")
    check markPersisted("b", BlobId(""))
    # 80 clean bytes; admitting c(40) must evict the LRU clean entry (a).
    check admit(inlinePaste("c", repeat(40)), repeat(40), "ip1")
    check getDisplayPaste("a").isNone
    check getDisplayPaste("b").isSome
    check getDisplayPaste("c").isSome

  test "markPersisted flips dirty->clean so the entry becomes evictable":
    resetForTest(100)
    check admit(inlinePaste("a", repeat(40)), repeat(40), "ip1")
    check markPersisted("a", BlobId(""))
    # Now clean: a fresh 80-byte paste can evict it.
    check admit(inlinePaste("b", repeat(80)), repeat(80), "ip1")
    check getDisplayPaste("a").isNone

  test "read touches LRU so least-recently-read is evicted":
    resetForTest(100)
    check admit(inlinePaste("a", repeat(40)), repeat(40), "ip1")
    check markPersisted("a", BlobId(""))
    check admit(inlinePaste("b", repeat(40)), repeat(40), "ip1")
    check markPersisted("b", BlobId(""))
    discard getDisplayPaste("a")     # touch a -> now MRU; b is LRU
    check admit(inlinePaste("c", repeat(40)), repeat(40), "ip1")
    check getDisplayPaste("b").isNone
    check getDisplayPaste("a").isSome

  test "removeFromCache clears a dirty entry":
    resetForTest(100)
    check admit(inlinePaste("a", repeat(40)), repeat(40), "ip1")
    let rem = removeFromCache("a")
    check rem.wasCached
    check getDisplayPaste("a").isNone

  test "large paste: display serves preview, raw serves full":
    resetForTest(1000)
    check admit(largePaste("a", "PREVIEW"), "FULLCONTENT", "ip1")
    check getDisplayPaste("a").get.content == "PREVIEW"
    let rv = acquireForRaw("a")
    check rv.isSome
    check rv.get.dirty
    check rv.get.content == "FULLCONTENT"

  test "unknown id misses":
    resetForTest(1000)
    check getDisplayPaste("nope").isNone
    check acquireForRaw("nope").isNone
