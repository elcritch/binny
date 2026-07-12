type
  ZLevel* = int8

proc layer*(lvl: ZLevel): ZLevel {.exportabi.} = lvl
