type
  Renderer*[State] = ref object
    state*: State
    kind*: int
    contextActivation*: proc(renderer: Renderer[State]) {.nimcall.}
    lcd, subpixel, variants: bool
    lcdDesired, subpixelDesired, variantsDesired: bool

proc backendKind*[State](renderer: Renderer[State]): int = renderer.kind
proc backendKind*[State](renderer: Renderer[State], offset: int): int =
  renderer.kind + offset
proc defaultValue*[T](): T = default(T)
proc setTextLcdFiltering*[State](renderer: Renderer[State], enabled: bool) =
  renderer.lcdDesired = enabled
  renderer.lcd = enabled
proc textLcdFiltering*[State](renderer: Renderer[State]): bool = renderer.lcd
proc setTextSubpixelPositioning*[State](renderer: Renderer[State], enabled: bool) =
  renderer.subpixelDesired = enabled
  renderer.subpixel = enabled
proc textSubpixelPositioning*[State](renderer: Renderer[State]): bool = renderer.subpixel
proc setTextSubpixelGlyphVariants*[State](renderer: Renderer[State], enabled: bool) =
  renderer.variantsDesired = enabled
  renderer.variants = enabled
proc textSubpixelGlyphVariants*[State](renderer: Renderer[State]): bool {.inline.} =
  renderer.variants
proc replaceBackend*[State](renderer: Renderer[State], kind: int) =
  renderer.kind = kind
  renderer.lcd = renderer.lcdDesired
  renderer.subpixel = renderer.subpixelDesired
  renderer.variants = renderer.variantsDesired
