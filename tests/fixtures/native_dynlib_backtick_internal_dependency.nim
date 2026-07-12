import tables

type
  internalChild = object
    value*: float32

  internalNode = object
    children*: seq[internalChild]

proc makeRoot*(): OrderedTable[string, internalNode] {.exportabi.} =
  initOrderedTable[string, internalNode]()

proc passThrough*(value: internalNode): internalNode {.exportabi.} =
  value
