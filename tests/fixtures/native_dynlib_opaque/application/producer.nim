import ../backend
import std/tables

type
  NativeRenderer* = Renderer[State]
  NativeState* = State
  NativeLease* = Lease
  NativeTarget* = FloatTarget
  ChildKind = enum
    ckValue
    ckNested

  Child = object
    case kind: ChildKind
    of ckValue:
      value: int
    of ckNested:
      nested: ref NativeTableState

  Entries = object
    children: Table[int16, seq[Child]]
    roots: seq[Child]
    ready: bool

  NativeTableState* = ref object
    entries: OrderedTable[int8, Entries]
    generations: Table[int8, uint64]

proc newRenderer*(): NativeRenderer =
  result = NativeRenderer(state: newState())
  backend.`enabled=`(result, true)
  doAssert backend.enabled(result)

proc newNativeState*(): NativeState =
  newState()

proc newNativeLease*(): NativeLease =
  newLease()

proc leaseLabel*(lease: NativeLease): string =
  lease.label()

proc stateLabel*(state: NativeState): string =
  state.label()

proc renameState*(state: var NativeState, text: string) =
  state.rename(text)

proc consumeState*(state: sink NativeState): string =
  state.label()

proc releasedCount*(): int =
  releaseCount()

proc presentationTarget*(): NativeTarget =
  target()

proc targetArea*(target: NativeTarget): float32 =
  area(target)

proc newNativeTableState*(): NativeTableState =
  new(result)
  result.entries[1] = Entries(roots: @[Child(kind: ckValue, value: 1)])
  result.generations[1] = 1

proc tableValue*(state: NativeTableState, key: int): string {.raises: [].} =
  if state.generations.getOrDefault(key.int8) == 1:
    result = "one"

iterator tableKeys*(state: NativeTableState): int8 {.raises: [].} =
  for key in state.entries.keys:
    yield key
