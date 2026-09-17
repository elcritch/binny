import backend, renderer

type NativeRenderer* = Renderer[BackendState]
type OtherRenderer* = Renderer[OtherState]

proc releasedCount*(): int = destroyedCount()

proc newOtherRenderer*(): OtherRenderer =
  result = OtherRenderer(state: OtherState(value: 12), kind: 8)
  doAssert result.backendKind() == 8

proc newRenderer*(): NativeRenderer =
  result = NativeRenderer(state: BackendState(label: "native"), kind: 4)
  result.state.label.add '!'
  result.setTextLcdFiltering(true)
  result.setTextSubpixelPositioning(true)
  result.setTextSubpixelGlyphVariants(true)
  doAssert result.backendKind() == 4
  doAssert reflectedBackendKind(result) == 4
  result.contextActivation = proc(renderer: NativeRenderer) {.nimcall.} = inc renderer.kind
  doAssert result.backendKind(3) == 7
  doAssert result.textLcdFiltering()
  doAssert result.textSubpixelPositioning()
  doAssert result.textSubpixelGlyphVariants()
  result.replaceBackend(5)
  doAssert defaultValue[int]() == 0
  doAssert defaultValue[float]() == 0
