
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

proc takeU16LE*(data: openArray[byte]; idx: var int): uint16 {.inline.} =
  let a = uint16(data[idx]); inc idx
  let b = uint16(data[idx]); inc idx
  result = a or (b shl 8)

proc takeU16BE*(data: openArray[byte]; idx: var int): uint16 {.inline.} =
  let a = uint16(data[idx]); inc idx
  let b = uint16(data[idx]); inc idx
  result = (a shl 8) or b

proc takeU32LE*(data: openArray[byte]; idx: var int): uint32 {.inline.} =
  let b0 = uint32(data[idx]); inc idx
  let b1 = uint32(data[idx]); inc idx
  let b2 = uint32(data[idx]); inc idx
  let b3 = uint32(data[idx]); inc idx
  result = b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)

proc takeU32BE*(data: openArray[byte]; idx: var int): uint32 {.inline.} =
  let b0 = uint32(data[idx]); inc idx
  let b1 = uint32(data[idx]); inc idx
  let b2 = uint32(data[idx]); inc idx
  let b3 = uint32(data[idx]); inc idx
  result = (b0 shl 24) or (b1 shl 16) or (b2 shl 8) or b3

proc takeI32LE*(data: openArray[byte]; idx: var int): int32 {.inline.} =
  cast[int32](takeU32LE(data, idx))

proc takeI32BE*(data: openArray[byte]; idx: var int): int32 {.inline.} =
  cast[int32](takeU32BE(data, idx))

proc takeU16LE*(data: openArray[byte]; offset: int): uint16 =
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc takeU32LE*(data: openArray[byte]; offset: int): uint32 =
  uint32(data[offset]) or (uint32(data[offset + 1]) shl 8) or
  (uint32(data[offset + 2]) shl 16) or (uint32(data[offset + 3]) shl 24)

proc takeU64LE*(data: openArray[byte]; offset: int): uint64 =
  uint64(data[offset]) or (uint64(data[offset + 1]) shl 8) or
  (uint64(data[offset + 2]) shl 16) or (uint64(data[offset + 3]) shl 24) or
  (uint64(data[offset + 4]) shl 32) or (uint64(data[offset + 5]) shl 40) or
  (uint64(data[offset + 6]) shl 48) or (uint64(data[offset + 7]) shl 56)

proc getU16LE*(data: openArray[byte]; offset: int): uint16 =
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc getU32LE*(data: openArray[byte]; offset: int): uint32 =
  uint32(data[offset]) or (uint32(data[offset + 1]) shl 8) or
  (uint32(data[offset + 2]) shl 16) or (uint32(data[offset + 3]) shl 24)

proc getU64LE*(data: openArray[byte]; offset: int): uint64 =
  uint64(data[offset]) or (uint64(data[offset + 1]) shl 8) or
  (uint64(data[offset + 2]) shl 16) or (uint64(data[offset + 3]) shl 24) or
  (uint64(data[offset + 4]) shl 32) or (uint64(data[offset + 5]) shl 40) or
  (uint64(data[offset + 6]) shl 48) or (uint64(data[offset + 7]) shl 56)

# LEB128 decoding (used in DWARF)
proc readULeb128*(data: openArray[byte]; offset: var int): uint64 =
  result = 0
  var shift = 0
  while offset < data.len:
    let b = data[offset]
    inc offset
    result = result or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0:
      break
    shift += 7

proc readSLeb128*(data: openArray[byte]; offset: var int): int64 =
  result = 0
  var shift = 0
  var b: byte
  while offset < data.len:
    b = data[offset]
    inc offset
    result = result or (int64(b and 0x7F) shl shift)
    shift += 7
    if (b and 0x80) == 0:
      break

  # Sign extend if needed
  if shift < 64 and (b and 0x40) != 0:
    result = result or (not 0'i64 shl shift)

