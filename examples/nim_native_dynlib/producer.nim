import std/tables
import support
export support

type
  Vec2* = object
    x*, y*: float32

  Child* = ref object
    label*: string

  Renderer* = ref object
    name*: string
    size*: Vec2
    child*: Child

  Hooked* = object
    value*: int

  MoveOnly* = object
    value*: int

  PayloadKind* = enum
    pkCode
    pkText

  Payload* = object
    case kind*: PayloadKind
    of pkCode:
      code*: int
    of pkText:
      text*: string

  Base* {.inheritable.} = object
    baseValue*: int

  Derived* = object of Base
    detail*: string

  Packed* {.packed.} = object
    small*: uint8
    large*: uint32

  NumberSpan* = object
    value*: int

  Number* = int16

  RenderList* = seq[string]

  Renders* = ref object
    layers*: OrderedTable[Number, RenderList]

var
  hookedCopies = 0
  hookedDestroys = 0
  moveOnlyDestroys = 0

proc `=destroy`(hooked: Hooked) =
  if hooked.value != 0:
    inc hookedDestroys

proc `=copy`(dest: var Hooked, source: Hooked) =
  inc hookedCopies
  dest.value = source.value

proc `=destroy`(moveOnly: MoveOnly) =
  if moveOnly.value != 0:
    inc moveOnlyDestroys

proc `=copy`(dest: var MoveOnly, source: MoveOnly) {.error.}

proc newRenderer*(name: string): Renderer =
  Renderer(name: name, size: Vec2(x: 1, y: 2), child: Child(label: "child"))

proc translate*(renderer: Renderer, delta: Vec2) =
  renderer.size.x += delta.x
  renderer.size.y += delta.y

proc describe*(renderer: Renderer): string =
  renderer.name & ":" & renderer.child.label

proc message*(): string =
  "hello from the MY AWESOME dynlib"

proc sumNumbers*(numbers: openArray[int]): int =
  for number in numbers:
    result += number

proc sumSpans*(spans: openArray[NumberSpan]): int =
  for span in spans:
    result += span.value

proc sumLabeledSpans*(spans: openArray[(NumberSpan, string)]): int =
  for (span, label) in spans:
    result += span.value + label.len

proc doubleNumber*(number: Number): Number =
  number * 2

proc newRenders*(): Renders =
  Renders(layers: initOrderedTable[Number, RenderList]())

proc newTextPayload*(text: string): Payload =
  Payload(kind: pkText, text: text)

proc payloadDescription*(payload: Payload): string =
  case payload.kind
  of pkCode:
    $payload.code
  of pkText:
    payload.text

proc newDerived*(value: int, detail: string): Derived =
  Derived(baseValue: value, detail: detail)

proc derivedDescription*(value: Derived): string =
  $value.baseValue & ":" & value.detail

proc newPacked*(small: uint8, large: uint32): Packed =
  Packed(small: small, large: large)

proc newHooked*(value: int): Hooked =
  Hooked(value: value)

proc hookedCopyCount*(): int =
  hookedCopies

proc hookedDestroyCount*(): int =
  hookedDestroys

proc newMoveOnly*(value: int): MoveOnly =
  MoveOnly(value: value)

proc ignoredDebugMessage*(): string {.noinline.} =
  "not part of the native API"

proc ignoredMetric*(value: int): int {.noinline.} =
  value + 1
