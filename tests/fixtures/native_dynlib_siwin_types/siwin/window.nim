import std/options
import vmath

type
  Window* = ref object of RootObj
    value*: int
  Edge* = enum
    left, right
  PixelBuffer* = object
    width*, height*: int
    data*: seq[uint8]
  LocalVec2* = object
    x*, y*: float32

method startInteractiveMove*(window: Window, pos: Option[Vec2] = none Vec2) {.base.} =
  static:
    doAssert sizeof(pos) == 12
    doAssert alignof(pos) == 4
  window.value = -100
method startInteractiveResize*(window: Window, edge: Edge,
    pos: Option[Vec2] = none Vec2) {.base.} =
  window.value = -100
method showWindowMenu*(window: Window, pos: Option[Vec2] = none Vec2) {.base.} =
  window.value = -100
method `icon=`*(window: Window, value: typeof(nil)) {.base.} =
  window.value = -100
method `icon=`*(window: Window, value: PixelBuffer) {.base.} =
  window.value = -100

proc widePosition*(pos: Option[DVec2]): int =
  static:
    doAssert sizeof(pos) == 24
    doAssert alignof(pos) == 8
  if pos.isSome: int(pos.get.x + pos.get.y) else: -5

proc localPosition*(pos: Option[LocalVec2]): int =
  if pos.isSome: int(pos.get.x + pos.get.y) else: -6
