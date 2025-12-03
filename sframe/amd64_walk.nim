import std/options
import sframe

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

proc walkStackAmd64*(sec: SFrameSection; sectionBase, startPc, startSp, startFp: uint64; mem: SimMemory; maxFrames: int = 16): seq[uint64] =
  ## Minimal AMD64 stack walker using SFrame data. Returns PCs from top to bottom.
  var pc = startPc
  var sp = startSp
  var fp = startFp
  var frames: seq[uint64] = @[]
  for _ in 0 ..< maxFrames:
    frames.add pc
    let (found, _, _, freGlobalIdx) = sec.pcToFre(pc, sectionBase)
    if not found: break
    let fre = sec.fres[freGlobalIdx]
    let off = freOffsetsForAbi(sframeAbiAmd64Little, sec.header, fre)
    let baseVal = if off.cfaBase == sframeCfaBaseSp: sp else: fp
    let cfa = baseVal + uint64(cast[int64](off.cfaFromBase))
    if off.raFromCfa.isNone(): break
    let raAddr = cfa + uint64(cast[int64](off.raFromCfa.get()))
    let nextPc = mem.loadU64(raAddr)
    if nextPc == 0'u64: break
    var nextFp = fp
    if off.fpFromCfa.isSome():
      let fpAddr = cfa + uint64(cast[int64](off.fpFromCfa.get()))
      nextFp = mem.loadU64(fpAddr)
    pc = nextPc
    sp = cfa
    fp = nextFp
  result = frames

