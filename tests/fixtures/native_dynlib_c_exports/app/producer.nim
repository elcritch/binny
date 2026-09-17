import ../dep/pixie
import ../other/common as otherCommon
import std/unicode

type Owned* = object
  data*: ptr int

var released: int

proc `=destroy`(value: Owned) =
  if value.data != nil:
    dealloc value.data
    inc released
proc `=copy`(destination: var Owned, source: Owned) {.error.}
proc `=dup`(source: Owned): Owned {.error.}

proc newOwned*(value: int): Owned =
  result.data = cast[ptr int](alloc(sizeof(int)))
  result.data[] = value
proc consumeOwned*(value: sink Owned): int {.inline.} = value.data[]
proc releasedCount*(): int = released

proc producerValue*(): int =
  copy(newImage(3, 4), 1).width + otherCommon.newImage(3, 4) + otherCommon.copy(1)

discard producerValue()
markInitialized()
discard runeLenAt("a", 0)
