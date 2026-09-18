var visited = 0

proc visitedCount*(): int = visited
proc resetVisited*() = visited = 0

iterator counting*(limit: int): int {.raises: [].} =
  for value in 0..<limit:
    inc visited
    yield value

iterator counting*(text: string): string {.raises: [].} =
  for index in 0..<text.len:
    yield text[0..index]

iterator resumable*(limit: int): int {.closure, raises: [].} =
  for value in 0..<limit:
    yield value * 2

iterator entries*(text: string): tuple[index: int, text: string] {.raises: [].} =
  for index in 0..<text.len:
    yield (index, text[0..index])

iterator mutableValues*(values: var seq[int]): var int {.raises: [].} =
  for value in values.mitems:
    yield value

iterator borrowedValues*(values: openArray[int]): int {.raises: [].} =
  for value in values:
    yield value

iterator excluded*(): int {.raises: [].} =
  yield 999

iterator genericValues*[T](values: seq[T]): T {.raises: [].} =
  for value in values:
    yield value

# Retain a concrete specialization in the compiler's semantic artifacts.
for value in genericValues(@[4, 5]):
  discard value

iterator changing*(value: int): int {.closure, raises: [].} =
  yield value
  yield value

iterator pulses*(value: var int) {.closure, raises: [].} =
  inc value
  yield
  inc value
  yield

type IntIterator* = iterator(limit: int): int {.closure.}
proc makeIterator*(): IntIterator = resumable

var released = 0
var finalized = 0
type Guard = object
  active: bool
proc `=destroy`(guard: Guard) =
  if guard.active: inc released
proc releasedCount*(): int = released
proc finalizedCount*(): int = finalized

iterator guarded*(): int {.raises: [].} =
  let guard = Guard(active: true)
  defer: inc finalized
  yield 1
  yield 2
  discard guard

iterator ownedValues*(values: sink seq[string]): string {.raises: [].} =
  for value in values:
    yield value

iterator keywordValues*(`type`, binnyIterator: int): int {.raises: [].} =
  yield `type`
  yield binnyIterator

iterator genericClosure*[T](value: T): T {.closure, raises: [].} =
  yield value
  yield value

for value in genericClosure("seed"):
  discard value

iterator privateValues(): int {.raises: [].} =
  yield 10

iterator uninstantiated*[T](value: T): T {.raises: [].} =
  yield value
