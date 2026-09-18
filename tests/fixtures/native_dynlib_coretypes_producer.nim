import std/[deques, sets, tables]

type
  Small* = range[-4'i16..6'i16]
  Letter* = range['a'..'z']
  Fraction* = range[0.0'f32..1.0'f32]
  Wide* = range[9223372036854775808'u64..18446744073709551615'u64]
  Level* = enum lowLevel, middleLevel, highLevel
  Mid* = range[middleLevel..highLevel]
  Samples* = UncheckedArray[float32]
  SampleBuffer* = ptr Samples
  IntRef* = ref int
  IntPtr* = ptr int
  Point* = object
    x*: int

type CoreState* = ref object
  values*: HashSet[int]
  ordered*: OrderedSet[string]
  counts*: CountTable[string]
  tableRef*: TableRef[int, string]
  orderedRef*: OrderedTableRef[int, string]
  countRef*: CountTableRef[string]
  pending*: Deque[Slice[int]]
  nested*: Table[string, HashSet[int]]
  small*: Small
  letter*: Letter
  fraction*: Fraction
  wide*: Wide
  mid*: Mid
  indexed*: array[Small, int16]
  letters*: set[Letter]
  samples*: SampleBuffer
  position*: ptr int32
  pointRef*: ref Point
  pointPtr*: ptr Point
  integers*: IntRef

proc newCoreState*(): CoreState =
  CoreState(
    values: toHashSet([2, 4]),
    ordered: toOrderedSet(["first", "second"]),
    counts: toCountTable(["apple", "apple"]),
    tableRef: newTable[int, string](),
    orderedRef: newOrderedTable[int, string](),
    countRef: newCountTable[string](),
    pending: initDeque[Slice[int]](),
    letter: 'a',
    wide: low(Wide),
    mid: middleLevel,
  )

proc inspectCoreState*(state: CoreState): bool {.raises: [].} =
  var ordered: seq[string]
  for value in state.ordered:
    ordered.add value
  7 in state.values and ordered == @["first", "second", "third"] and
    state.counts.getOrDefault("apple") == 3 and
    state.tableRef.getOrDefault(5) == "five" and
    state.orderedRef.getOrDefault(6) == "six" and
    state.countRef.getOrDefault("pear", 0) == 2 and
    state.pending.peekFirst() == 3..8 and
    9 in state.nested.getOrDefault("nested")

proc roundTripSet*(values: HashSet[string]): HashSet[string] = values
proc roundTripDeque*(values: Deque[int16]): Deque[int16] = values

proc roundTripSmall*(value: Small): Small = value
proc roundTripLetter*(value: Letter): Letter = value
proc roundTripFraction*(value: Fraction): Fraction = value
proc roundTripWide*(value: Wide): Wide = value
proc roundTripMid*(value: Mid): Mid = value
proc anonymousRange*(value: range[-3..7]): range[-3..7] = value
proc sumSamples*(samples: ptr UncheckedArray[float32], count: int): float32 =
  for index in 0..<count:
    result += samples[index]
proc increment*(value: IntPtr): IntPtr =
  inc value[]
  value
proc newIntRef*(value: int): IntRef =
  new result
  result[] = value
proc inspectBuffers*(state: CoreState): bool =
  state.samples[1] == 2.0 and state.position[] == 12 and
    state.pointRef.x == 5 and state.pointPtr.x == 6 and state.integers[] == 7 and
    state.indexed[-4] == 8 and 'c' in state.letters

type Owner* = object
  data*: ptr int

var destructions: int

proc `=destroy`(value: Owner) =
  if value.data != nil:
    dealloc value.data
    inc destructions
proc `=copy`(destination: var Owner, source: Owner) {.error.}
proc `=dup`(source: Owner): Owner {.error.}

type OwnerHolder* = ref object
  value*: Owner
  onConsume*: proc(value: sink Owner): int
  onBorrow*: proc(): lent Owner

proc newOwner*(value: int): Owner =
  result.data = cast[ptr int](alloc(sizeof(int)))
  result.data[] = value
proc consumeOwner*(value: sink Owner): int = value.data[]
proc consumeOwners*(first, second: sink Owner): int = first.data[] + second.data[]
proc consumeStrings*(values: sink seq[string]): int = values.len
proc inspectOwner*(value: Owner): int = value.data[]
proc newOwnerHolder*(value: int): OwnerHolder = OwnerHolder(value: newOwner(value))
proc borrowOwner*(holder: OwnerHolder): lent Owner = holder.value
proc borrowMutable*(holder: OwnerHolder): var Owner = holder.value
proc destructionCount*(): int = destructions
