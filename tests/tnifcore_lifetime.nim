import std/unittest
import binny/native_dynlib/nif/[nifcore, nifqueries]

suite "token buffer ownership":
  test "releases pool references without an outstanding cursor":
    let pool = newPool()
    let tags = newTagPool()
    for revision in 0..<50:
      block:
        var buffer = createTokenBuf(sharedPool = pool, sharedTags = tags)
        buffer.buildTree buffer.tags.registerTag("module"):
          buffer.addSymUse("value.0.sample")
        var cursor = buffer.beginRead()
        check cursor.tagName == "module"
        cursor.endRead()
      check isUniqueRef(pool)
      check isUniqueRef(tags)

  test "a cursor owns tokens and pools beyond buffer lifetime":
    let pool = newPool()
    let tags = newTagPool()
    var retained: Cursor
    block:
      var buffer = createTokenBuf(sharedPool = pool, sharedTags = tags)
      buffer.addSymUse("retained.0.sample")
      retained = buffer.beginRead()
    check retained.symName == "retained.0.sample"
    block:
      var copied = retained
      retained.endRead()
      check copied.symName == "retained.0.sample"
      copied.endRead()
    check isUniqueRef(pool)
    check isUniqueRef(tags)
