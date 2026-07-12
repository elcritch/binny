import generated/producer_abi
import std/tables

echo "Producer says: ", message()

let values = [3, 5, 8]
doAssert sumNumbers(values) == 16

let spans = [NumberSpan(value: 13), NumberSpan(value: 21)]
doAssert sumSpans(spans) == 34
doAssert sumLabeledSpans([(NumberSpan(value: 5), "abc")]) == 8

let number: Number = 12
doAssert doubleNumber(number) == 24

let renders = newRenders()
renders.layers[1.Number] = @["first"]
renders.layers[2.Number] = @["second", "third"]
doAssert 1.Number in renders.layers
doAssert renders.layers[2.Number] == @["second", "third"]
var visited: seq[(Number, RenderList)]
for key, value in renders.layers:
  visited.add (key, value)
doAssert visited == @[
  (1.Number, @["first"]),
  (2.Number, @["second", "third"])
]

let payload = newTextPayload("case object")
doAssert payload.kind == pkText
doAssert payload.text == "case object"
doAssert payloadDescription(payload) == "case object"

let derived = newDerived(12, "inherited")
doAssert derived.baseValue == 12
doAssert derived.detail == "inherited"
doAssert derivedDescription(derived) == "12:inherited"

let packed = newPacked(1, 0xAABBCCDD'u32)
doAssert packed.small == 1
doAssert packed.large == 0xAABBCCDD'u32

let imported = newImportedValue("other module")
doAssert imported.label == "other module"
doAssert importedLabel(imported) == "other module"

block customHooks:
  let original = newHooked(7)
  var copied: Hooked
  copied = original
  doAssert copied.value == 7
  doAssert hookedCopyCount() == 1

doAssert hookedDestroyCount() == 2

let moveOnly = newMoveOnly(9)
doAssert moveOnly.value == 9

let renderer = newRenderer("main")
doAssert renderer.name == "main"
doAssert renderer.size.x == 1
doAssert renderer.size.y == 2
doAssert renderer.child.label == "child"
doAssert describe(renderer) == "main:child"

renderer.name = "consumer"
renderer.child.label = "updated"
translate(renderer, Vec2(x: 3, y: 4))

doAssert renderer.name == "consumer"
doAssert renderer.size.x == 4
doAssert renderer.size.y == 6
doAssert describe(renderer) == "consumer:updated"
