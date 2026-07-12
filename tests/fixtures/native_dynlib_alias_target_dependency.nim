type
  ColorLUV* = object
    hue*: float32
    sat*: float32
    lum*: float32

  ColorHCL* = ColorLUV

proc transform*(value: ColorHCL): ColorHCL {.exportabi.} = value
