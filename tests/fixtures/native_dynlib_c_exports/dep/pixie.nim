import common
export common

var initialized: bool
proc markInitialized*() = initialized = true
proc producerInitialized*(): bool = initialized

proc readImage*(value: string): Image {.inline.} =
  newImage(value.len, 2)

proc readImage*(value: int): Image {.inline.} = newImage(value, 3)

proc sumValues*(values: openArray[int]): int {.inline.} =
  for value in values:
    result += value

proc consumeStrings*(values: sink seq[string]): int {.inline.} = values.len
proc borrowWidth*(image: Image): lent int {.inline.} = image.width
proc mutableWidth*(image: Image): var int {.inline.} = image.width

{.push inline.}
proc inheritedInline*(value: int): int = value + 1
{.pop.}
