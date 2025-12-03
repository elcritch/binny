import std/options
import sframe
import sframe/mem_sim
export mem_sim

type U64Reader* = proc (address: uint64): uint64 {.gcsafe.}

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

proc walkStackAmd64With*(sec: SFrameSection; sectionBase, startPc, startSp, startFp: uint64; readU64: U64Reader; maxFrames: int = 16): seq[uint64] =
  ## AMD64 stack walker using a memory read callback.
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
    let nextPc = readU64(raAddr)
    if nextPc == 0'u64: break
    var nextFp = fp
    if off.fpFromCfa.isSome():
      let fpAddr = cfa + uint64(cast[int64](off.fpFromCfa.get()))
      nextFp = readU64(fpAddr)
    pc = nextPc
    sp = cfa
    fp = nextFp
  result = frames
