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

var
  hookedCopies = 0
  hookedDestroys = 0
  moveOnlyDestroys = 0

proc `=destroy`(hooked: Hooked) =
  if hooked.value != 0:
    inc hookedDestroys

proc `=copy`(dest: var Hooked; source: Hooked) =
  inc hookedCopies
  dest.value = source.value

proc `=destroy`(moveOnly: MoveOnly) =
  if moveOnly.value != 0:
    inc moveOnlyDestroys

proc `=copy`(dest: var MoveOnly; source: MoveOnly) {.error.}

proc newRenderer*(name: string): Renderer {.exportabi.} =
  Renderer(
    name: name,
    size: Vec2(x: 1, y: 2),
    child: Child(label: "child"))

proc translate*(renderer: Renderer; delta: Vec2) {.exportabi.} =
  renderer.size.x += delta.x
  renderer.size.y += delta.y

proc describe*(renderer: Renderer): string {.exportabi.} =
  renderer.name & ":" & renderer.child.label

proc message*(): string {.exportabi.} =
  "hello from the MY AWESOME dynlib"

proc sumNumbers*(numbers: openArray[int]): int {.exportabi.} =
  for number in numbers:
    result += number

proc sumSpans*(spans: openArray[NumberSpan]): int {.exportabi.} =
  for span in spans:
    result += span.value

proc newTextPayload*(text: string): Payload {.exportabi.} =
  Payload(kind: pkText, text: text)

proc payloadDescription*(payload: Payload): string {.exportabi.} =
  case payload.kind
  of pkCode: $payload.code
  of pkText: payload.text

proc newDerived*(value: int; detail: string): Derived {.exportabi.} =
  Derived(baseValue: value, detail: detail)

proc derivedDescription*(value: Derived): string {.exportabi.} =
  $value.baseValue & ":" & value.detail

proc newPacked*(small: uint8; large: uint32): Packed {.exportabi.} =
  Packed(small: small, large: large)

proc newHooked*(value: int): Hooked {.exportabi.} =
  Hooked(value: value)

proc hookedCopyCount*(): int {.exportabi.} =
  hookedCopies

proc hookedDestroyCount*(): int {.exportabi.} =
  hookedDestroys

proc newMoveOnly*(value: int): MoveOnly {.exportabi.} =
  MoveOnly(value: value)
