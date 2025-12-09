type SimMemory* = object
  base*: uint64
  bytes*: seq[byte]

proc initSimMemory*(base: uint64; size: int): SimMemory =
  SimMemory(base: base, bytes: newSeq[byte](size))

proc offsetIdx(mem: SimMemory; address: uint64): int =
  let d = address - mem.base
  if d >= uint64(mem.bytes.len):
    raise newException(IndexDefect, "address out of range")
  int(d)

proc storeU64*(mem: var SimMemory; address: uint64; value: uint64) =
  var i = mem.offsetIdx(address)
  when system.cpuEndian == littleEndian:
    mem.bytes[i+0] = byte(value and 0xFF)
    mem.bytes[i+1] = byte((value shr 8) and 0xFF)
    mem.bytes[i+2] = byte((value shr 16) and 0xFF)
    mem.bytes[i+3] = byte((value shr 24) and 0xFF)
    mem.bytes[i+4] = byte((value shr 32) and 0xFF)
    mem.bytes[i+5] = byte((value shr 40) and 0xFF)
    mem.bytes[i+6] = byte((value shr 48) and 0xFF)
    mem.bytes[i+7] = byte((value shr 56) and 0xFF)
  else:
    mem.bytes[i+0] = byte((value shr 56) and 0xFF)
    mem.bytes[i+1] = byte((value shr 48) and 0xFF)
    mem.bytes[i+2] = byte((value shr 40) and 0xFF)
    mem.bytes[i+3] = byte((value shr 32) and 0xFF)
    mem.bytes[i+4] = byte((value shr 24) and 0xFF)
    mem.bytes[i+5] = byte((value shr 16) and 0xFF)
    mem.bytes[i+6] = byte((value shr 8) and 0xFF)
    mem.bytes[i+7] = byte(value and 0xFF)

proc loadU64*(mem: SimMemory; address: uint64): uint64 =
  let i = mem.offsetIdx(address)
  when system.cpuEndian == littleEndian:
    result = (uint64(mem.bytes[i+0]) or
              (uint64(mem.bytes[i+1]) shl 8) or
              (uint64(mem.bytes[i+2]) shl 16) or
              (uint64(mem.bytes[i+3]) shl 24) or
              (uint64(mem.bytes[i+4]) shl 32) or
              (uint64(mem.bytes[i+5]) shl 40) or
              (uint64(mem.bytes[i+6]) shl 48) or
              (uint64(mem.bytes[i+7]) shl 56))
  else:
    result = ((uint64(mem.bytes[i+0]) shl 56) or
              (uint64(mem.bytes[i+1]) shl 48) or
              (uint64(mem.bytes[i+2]) shl 40) or
              (uint64(mem.bytes[i+3]) shl 32) or
              (uint64(mem.bytes[i+4]) shl 24) or
              (uint64(mem.bytes[i+5]) shl 16) or
              (uint64(mem.bytes[i+6]) shl 8) or
              (uint64(mem.bytes[i+7])))

