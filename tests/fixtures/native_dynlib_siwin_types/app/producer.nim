import std/options
import vmath
import ../siwin/window

type DerivedWindow = ref object of Window

method startInteractiveMove(window: DerivedWindow, pos: Option[Vec2] = none Vec2) =
  window.value = if pos.isSome: int(pos.get.x + pos.get.y) else: -1
method startInteractiveResize(window: DerivedWindow, edge: Edge,
    pos: Option[Vec2] = none Vec2) =
  window.value = if pos.isSome: int(pos.get.x) + ord(edge) else: -2
method showWindowMenu(window: DerivedWindow, pos: Option[Vec2] = none Vec2) =
  window.value = if pos.isSome: int(pos.get.y) else: -3
method `icon=`(window: DerivedWindow, value: typeof(nil)) =
  window.value = -4
method `icon=`(window: DerivedWindow, value: PixelBuffer) =
  window.value = value.width + value.height + int(value.data[0])

proc newWindow*(): Window = DerivedWindow()
