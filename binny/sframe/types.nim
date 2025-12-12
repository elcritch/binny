import std/[strformat]
import std/options

import ../utils
export utils

# Minimal SFrame scaffolding based on docs/sframe-spec.md

# Constants
const
  SFRAME_MAGIC* = 0xDEE2'u16
  SFRAME_VERSION_1* = 1'u8
  SFRAME_VERSION_2* = 2'u8

# Section-wide flags (subset for now)
type SFrameFlags* = distinct uint8

const
  SFRAME_F_FDE_SORTED* = SFrameFlags(0x01'u8)
  SFRAME_F_FRAME_POINTER* = SFrameFlags(0x02'u8)
  SFRAME_F_FDE_FUNC_START_PCREL* = SFrameFlags(0x04'u8) # v2 errata 1

proc hasFlag*(flags: SFrameFlags, flag: SFrameFlags): bool {.inline.} =
  (uint8(flags) and uint8(flag)) != 0

# 2.1 SFrame Preamble
type SFramePreamble* {.packed.} = object
  magic*: uint16 # 0xDEE2
  version*: uint8 # 1 or 2
  flags*: uint8 # section flags

proc isValid*(pre: SFramePreamble): bool =
  ## Basic validation of the preamble fields
  (pre.magic == SFRAME_MAGIC) and
    (pre.version == SFRAME_VERSION_1 or pre.version == SFRAME_VERSION_2)

# 2.2 SFrame Header
type
  SFrameAbiArch* = enum
    sframeAbiInvalid = 0
    sframeAbiAarch64Big = 1
    sframeAbiAarch64Little = 2
    sframeAbiAmd64Little = 3
    sframeAbiS390xBig = 4

  SFrameHeader* {.packed.} = object
    preamble*: SFramePreamble
    abiArch*: uint8 # SFrameAbiArch encoded
    cfaFixedFpOffset*: int8
    cfaFixedRaOffset*: int8
    auxHdrLen*: uint8
    numFdes*: uint32
    numFres*: uint32
    freLen*: uint32
    fdeOff*: uint32
    freOff*: uint32
    auxData*: seq[byte]

proc sizeofSFrameHeaderFixed*(): int {.inline.} =
  28 # bytes, without aux bytes

# 2.3 SFrame FDE info word helpers
type
  SFrameFdeType* = enum
    sframeFdePcInc = 0
    sframeFdePcMask = 1

  SFrameFreType* = enum
    sframeFreAddr1 = 0
    sframeFreAddr2 = 1
    sframeFreAddr4 = 2

  SFrameFdeInfo* = distinct uint8

proc `==`*(a, b: SFrameFdeInfo): bool {.inline.} =
  uint8(a) == uint8(b)

proc fdeInfo*(
    freType: SFrameFreType, fdeType: SFrameFdeType, aarch64PauthKeyB = false
): SFrameFdeInfo =
  var v: uint8 = uint8(freType) and 0x0F
  v = v or (uint8(fdeType) shl 4)
  if aarch64PauthKeyB:
    v = v or (1'u8 shl 5)
  SFrameFdeInfo(v)

proc fdeInfoGetFreType*(info: SFrameFdeInfo): SFrameFreType {.inline.} =
  SFrameFreType(uint8(info) and 0x0F)

proc fdeInfoGetFdeType*(info: SFrameFdeInfo): SFrameFdeType {.inline.} =
  SFrameFdeType((uint8(info) shr 4) and 0x01)

proc fdeInfoGetAarch64PauthKeyB*(info: SFrameFdeInfo): bool {.inline.} =
  ((uint8(info) shr 5) and 0x01) == 1

type SFrameFDE* {.packed.} = object
  funcStartAddress*: int32
  funcSize*: uint32
  funcStartFreOff*: uint32
  funcNumFres*: uint32
  funcInfo*: SFrameFdeInfo
  funcRepSize*: uint8
  funcPadding2*: uint16

proc sizeofSFrameFDE*(): int {.inline.} =
  20

# 2.4 SFrame FRE info and entries
type
  SFrameOffsetSize* = enum
    sframeFreOff1B = 0
    sframeFreOff2B = 1
    sframeFreOff4B = 2

  SFrameCfaBase* = enum
    sframeCfaBaseFp = 0
    sframeCfaBaseSp = 1

  SFrameFreInfo* = distinct uint8

proc `==`*(a, b: SFrameFreInfo): bool {.inline.} =
  uint8(a) == uint8(b)

proc freInfo*(
    cfaBase: SFrameCfaBase,
    offsetCount: range[0 .. 15],
    offsetSize: SFrameOffsetSize,
    mangledRa = false,
): SFrameFreInfo =
  var v: uint8 = 0
  if cfaBase == sframeCfaBaseSp:
    v = v or 0x01
  v = v or (uint8(offsetCount and 0x0F) shl 1)
  v = v or (uint8(offsetSize) shl 5)
  if mangledRa:
    v = v or 0x80'u8
  SFrameFreInfo(v)

proc freInfoGetCfaBase*(info: SFrameFreInfo): SFrameCfaBase {.inline.} =
  if (uint8(info) and 0x01) == 0: sframeCfaBaseFp else: sframeCfaBaseSp

proc freInfoGetOffsetCount*(info: SFrameFreInfo): int {.inline.} =
  int((uint8(info) shr 1) and 0x0F)

proc freInfoGetOffsetSize*(info: SFrameFreInfo): SFrameOffsetSize {.inline.} =
  SFrameOffsetSize((uint8(info) shr 5) and 0x03)

proc freInfoGetMangledRa*(info: SFrameFreInfo): bool {.inline.} =
  ((uint8(info) and 0x80) != 0)

proc freInfoOffsetByteSize*(info: SFrameFreInfo): int {.inline.} =
  case freInfoGetOffsetSize(info)
  of sframeFreOff1B: 1
  of sframeFreOff2B: 2
  of sframeFreOff4B: 4

type SFrameFRE* = object
  startAddr*: uint32 # stored width depends on freType
  info*: SFrameFreInfo
  offsets*: seq[int32] # sign-extended values

# Full section container and encode/decode
type SFrameSection* = object
  header*: SFrameHeader
  fdes*: seq[SFrameFDE]
  fres*: seq[SFrameFRE] # concatenated in function order

# ---- ABI-specific interpretation helpers ----

type FreOffsets* = object
  cfaBase*: SFrameCfaBase
  cfaFromBase*: int32
  raFromCfa*: Option[int32]
  fpFromCfa*: Option[int32]

proc freOffsetsForAbi*(
    abi: SFrameAbiArch, hdr: SFrameHeader, fre: SFrameFRE
): FreOffsets {.raises: [].} =
  ## Compute CFA/RA/FP offsets per ABI from a FRE and header.
  result.cfaBase = fre.info.freInfoGetCfaBase()
  if fre.offsets.len == 0:
    # Gracefully handle empty offsets: leave RA/FP as none and cfaFromBase = 0.
    result.cfaFromBase = 0
    result.raFromCfa = none(int32)
    result.fpFromCfa = none(int32)
    return
  result.cfaFromBase = fre.offsets[0]
  case abi
  of sframeAbiAmd64Little:
    # RA fixed from header; FP in FRE if present
    result.raFromCfa = some(int32(hdr.cfaFixedRaOffset))
    # Prefer per-FRE FP offset when present; otherwise fall back to fixed header FP offset
    if fre.offsets.len >= 2:
      result.fpFromCfa = some(fre.offsets[1])
    elif hdr.cfaFixedFpOffset != 0'i8:
      # Some toolchains encode a fixed FP-from-CFA offset in the header for amd64
      result.fpFromCfa = some(int32(hdr.cfaFixedFpOffset))
    else:
      # For AMD64, when no explicit FP offset is present, use -1 as sentinel (matching libsframe)
      result.fpFromCfa = some(-1'i32)
  of sframeAbiAarch64Big, sframeAbiAarch64Little:
    # RA and FP tracked in FRE when present (N == 3)
    if fre.offsets.len >= 2:
      result.raFromCfa = some(fre.offsets[1])
    if fre.offsets.len >= 3:
      result.fpFromCfa = some(fre.offsets[2])
  of sframeAbiS390xBig:
    # Minimal handling: follow similar pattern if present
    if fre.offsets.len >= 2:
      result.raFromCfa = some(fre.offsets[1])
    if fre.offsets.len >= 3:
      result.fpFromCfa = some(fre.offsets[2])
  else:
    discard

# ---- Address computations and lookups ----

proc headerByteLen*(h: SFrameHeader): int {.inline.} =
  sizeofSFrameHeaderFixed() + int(h.auxHdrLen)

proc funcStartAddress*(sec: SFrameSection, fdeIdx: int, sectionBase: uint64): uint64 =
  ## Compute function start virtual address for FDE index given section base address.
  let hdr = sec.header
  let fde = sec.fdes[fdeIdx]
  let flags = SFrameFlags(hdr.preamble.flags)
  let fs = uint64(cast[int64](fde.funcStartAddress))
  if flags.hasFlag(SFRAME_F_FDE_FUNC_START_PCREL):
    # Offset from the field itself
    let fieldAddr =
      sectionBase +
      uint64(hdr.headerByteLen() + int(hdr.fdeOff) + fdeIdx * sizeofSFrameFDE())
    result = fieldAddr + fs
  else:
    # Offset from start of SFrame section
    result = sectionBase + fs

proc funcFreStartIndex*(sec: SFrameSection, fdeIdx: int): int =
  ## Compute the global index in sec.fres where fdeIdx's FREs begin.
  var idx = 0
  for i in 0 ..< fdeIdx:
    idx += int(sec.fdes[i].funcNumFres)
  idx

proc findFdeIndexByPc*(sec: SFrameSection, pc: uint64, sectionBase: uint64): int =
  ## Binary search FDE by PC. Returns -1 if not found.
  if sec.fdes.len == 0:
    return -1
  let flags = SFrameFlags(sec.header.preamble.flags)
  # Expect sorted if flag set; we still binary search regardless.
  var lo = 0
  var hi = sec.fdes.len - 1
  var res = -1
  while lo <= hi:
    let mid = (lo + hi) shr 1
    let start = sec.funcStartAddress(mid, sectionBase)
    let size = uint64(sec.fdes[mid].funcSize)
    if pc < start:
      if mid == 0:
        break
      hi = mid - 1
    elif pc >= start + size:
      lo = mid + 1
    else:
      res = mid
      break
  res

proc pcToFre*(
    sec: SFrameSection, pc: uint64, sectionBase: uint64
): tuple[found: bool, fdeIdx: int, freLocalIdx: int, freGlobalIdx: int] =
  ## Map a PC to the containing (FDE, FRE). Returns found=false if not matched.
  let fi = sec.findFdeIndexByPc(pc, sectionBase)
  if fi < 0:
    return (false, -1, -1, -1)
  let fde = sec.fdes[fi]
  let fstart = sec.funcStartAddress(fi, sectionBase)
  var offWithin: uint64
  let ftype = fde.funcInfo.fdeInfoGetFdeType()
  case ftype
  of sframeFdePcInc:
    offWithin = pc - fstart
  of sframeFdePcMask:
    let rep = uint64(fde.funcRepSize)
    if rep == 0:
      return (false, -1, -1, -1)
    offWithin = (pc - fstart) mod rep

  # Binary search in FREs for this function using startAddr
  let freStart = sec.funcFreStartIndex(fi)
  let n = int(fde.funcNumFres)
  if n == 0:
    return (false, -1, -1, -1)
  var lo = 0
  var hi = n - 1
  var best = -1
  while lo <= hi:
    let mid = (lo + hi) shr 1
    let sa = uint64(sec.fres[freStart + mid].startAddr)
    if sa <= offWithin:
      best = mid
      lo = mid + 1
    else:
      if mid == 0:
        break
      hi = mid - 1
  if best < 0:
    return (false, fi, -1, -1)
  (true, fi, best, freStart + best)
