
# Helpers for host-endian encoding/decoding of integers
proc putU16LE*(buf: var openArray[byte]; idx: var int; v: uint16) {.inline.} =
  buf[idx] = byte(v and 0xFF); inc idx
  buf[idx] = byte((v shr 8) and 0xFF); inc idx

proc putU16BE*(buf: var openArray[byte]; idx: var int; v: uint16) {.inline.} =
  buf[idx] = byte((v shr 8) and 0xFF); inc idx
  buf[idx] = byte(v and 0xFF); inc idx

proc putU32LE*(buf: var openArray[byte]; idx: var int; v: uint32) {.inline.} =
  buf[idx] = byte(v and 0xFF); inc idx
  buf[idx] = byte((v shr 8) and 0xFF); inc idx
  buf[idx] = byte((v shr 16) and 0xFF); inc idx
  buf[idx] = byte((v shr 24) and 0xFF); inc idx

proc putU32BE*(buf: var openArray[byte]; idx: var int; v: uint32) {.inline.} =
  buf[idx] = byte((v shr 24) and 0xFF); inc idx
  buf[idx] = byte((v shr 16) and 0xFF); inc idx
  buf[idx] = byte((v shr 8) and 0xFF); inc idx
  buf[idx] = byte(v and 0xFF); inc idx

proc putI32LE*(buf: var openArray[byte]; idx: var int; v: int32) {.inline.} =
  putU32LE(buf, idx, cast[uint32](v))

proc putI32BE*(buf: var openArray[byte]; idx: var int; v: int32) {.inline.} =
  putU32BE(buf, idx, cast[uint32](v))

proc getU16LE*(data: openArray[byte]; idx: var int): uint16 {.inline.} =
  let a = uint16(data[idx]); inc idx
  let b = uint16(data[idx]); inc idx
  result = a or (b shl 8)

proc getU16BE*(data: openArray[byte]; idx: var int): uint16 {.inline.} =
  let a = uint16(data[idx]); inc idx
  let b = uint16(data[idx]); inc idx
  result = (a shl 8) or b

proc getU32LE*(data: openArray[byte]; idx: var int): uint32 {.inline.} =
  let b0 = uint32(data[idx]); inc idx
  let b1 = uint32(data[idx]); inc idx
  let b2 = uint32(data[idx]); inc idx
  let b3 = uint32(data[idx]); inc idx
  result = b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)

proc getU32BE*(data: openArray[byte]; idx: var int): uint32 {.inline.} =
  let b0 = uint32(data[idx]); inc idx
  let b1 = uint32(data[idx]); inc idx
  let b2 = uint32(data[idx]); inc idx
  let b3 = uint32(data[idx]); inc idx
  result = (b0 shl 24) or (b1 shl 16) or (b2 shl 8) or b3

proc getI32LE*(data: openArray[byte]; idx: var int): int32 {.inline.} =
  cast[int32](getU32LE(data, idx))

proc getI32BE*(data: openArray[byte]; idx: var int): int32 {.inline.} =
  cast[int32](getU32BE(data, idx))

