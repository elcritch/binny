type
  PrivateSeq = seq[int]

  PublicBox* = object
    values*: PrivateSeq

proc makeBox*(): PublicBox {.exportabi.} =
  PublicBox(values: @[1, 2, 3])
