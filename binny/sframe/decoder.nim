import std/[strformat]
import std/options

import ./types

proc decodePreamble*(bytes: openArray[byte]): SFramePreamble =
  ## Decode a 4-byte preamble from the given bytes using host CPU endianness
  if bytes.len < 4:
    raise newException(ValueError, fmt"SFrame preamble requires 4 bytes, got {bytes.len}")
  var i = 0
  var m: uint16
  when system.cpuEndian == littleEndian:
    m = takeU16LE(bytes, i)
  else:
    m = takeU16BE(bytes, i)
  let ver = uint8(bytes[i]); inc i
  let flg = uint8(bytes[i]); inc i
  SFramePreamble(magic: m, version: ver, flags: flg)

proc decodeHeader*(bytes: openArray[byte]): SFrameHeader =
  ## Decode fixed header + aux header.
  if bytes.len < sizeofSFrameHeaderFixed():
    raise newException(ValueError, fmt"Header requires at least {sizeofSFrameHeaderFixed()} bytes, got {bytes.len}")
  var i = 0
  let pre = decodePreamble(bytes[i ..< i+4]); i += 4
  var h: SFrameHeader
  h.preamble = pre
  h.abiArch = uint8(bytes[i]); inc i
  h.cfaFixedFpOffset = cast[int8](bytes[i]); inc i
  h.cfaFixedRaOffset = cast[int8](bytes[i]); inc i
  h.auxHdrLen = uint8(bytes[i]); inc i
  when system.cpuEndian == littleEndian:
    h.numFdes = takeU32LE(bytes, i)
    h.numFres = takeU32LE(bytes, i)
    h.freLen = takeU32LE(bytes, i)
    h.fdeOff = takeU32LE(bytes, i)
    h.freOff = takeU32LE(bytes, i)
  else:
    h.numFdes = takeU32BE(bytes, i)
    h.numFres = takeU32BE(bytes, i)
    h.freLen = takeU32BE(bytes, i)
    h.fdeOff = takeU32BE(bytes, i)
    h.freOff = takeU32BE(bytes, i)
  let auxLen = int(h.auxHdrLen)
  if bytes.len < sizeofSFrameHeaderFixed() + auxLen:
    raise newException(ValueError, "Insufficient bytes for aux header")
  if auxLen > 0:
    h.auxData = @bytes[i ..< i+auxLen]
    i += auxLen
  result = h

proc decodeFDE*(bytes: openArray[byte]): SFrameFDE =
  if bytes.len < 20:
    raise newException(ValueError, fmt"FDE requires 20 bytes, got {bytes.len}")
  var i = 0
  var f: SFrameFDE
  when system.cpuEndian == littleEndian:
    f.funcStartAddress = takeI32LE(bytes, i)
    f.funcSize = takeU32LE(bytes, i)
    f.funcStartFreOff = takeU32LE(bytes, i)
    f.funcNumFres = takeU32LE(bytes, i)
  else:
    f.funcStartAddress = takeI32BE(bytes, i)
    f.funcSize = takeU32BE(bytes, i)
    f.funcStartFreOff = takeU32BE(bytes, i)
    f.funcNumFres = takeU32BE(bytes, i)
  f.funcInfo = SFrameFdeInfo(bytes[i]); inc i
  f.funcRepSize = bytes[i]; inc i
  when system.cpuEndian == littleEndian:
    f.funcPadding2 = takeU16LE(bytes, i)
  else:
    f.funcPadding2 = takeU16BE(bytes, i)
  result = f

proc decodeFRE*(bytes: openArray[byte]; freType: SFrameFreType): tuple[f: SFrameFRE, consumed: int] =
  var i = 0
  var start: uint32
  case freType
  of sframeFreAddr1:
    if bytes.len < 1 + 1: raise newException(ValueError, "Insufficient bytes for FRE addr1")
    start = uint32(bytes[i]); inc i
  of sframeFreAddr2:
    if bytes.len < 2 + 1: raise newException(ValueError, "Insufficient bytes for FRE addr2")
    when system.cpuEndian == littleEndian:
      start = uint32(takeU16LE(bytes, i))
    else:
      start = uint32(takeU16BE(bytes, i))
  of sframeFreAddr4:
    if bytes.len < 4 + 1: raise newException(ValueError, "Insufficient bytes for FRE addr4")
    when system.cpuEndian == littleEndian:
      start = takeU32LE(bytes, i)
    else:
      start = takeU32BE(bytes, i)
  # info
  let info = SFrameFreInfo(bytes[i]); inc i
  let n = info.freInfoGetOffsetCount()
  let osz = info.freInfoOffsetByteSize()
  let need = i + n * osz
  if bytes.len < need:
    raise newException(ValueError, fmt"Insufficient bytes for FRE offsets: need {need}, got {bytes.len}")
  var offs = newSeq[int32](n)
  for k in 0 ..< n:
    case osz
    of 1:
      let v = cast[int8](bytes[i]); inc i
      offs[k] = int32(v)
    of 2:
      var u: uint16
      when system.cpuEndian == littleEndian:
        u = takeU16LE(bytes, i)
      else:
        u = takeU16BE(bytes, i)
      offs[k] = int32(cast[int16](u))
    of 4:
      var v: int32
      when system.cpuEndian == littleEndian:
        v = takeI32LE(bytes, i)
      else:
        v = takeI32BE(bytes, i)
      offs[k] = int32(v)
    else:
      discard
  (SFrameFRE(startAddr: start, info: info, offsets: offs), i)

proc decodeSection*(bytes: openArray[byte]): SFrameSection =
  ## Decode a complete SFrame section into header, fdes, fres.
  # Header
  let hdr = decodeHeader(bytes)
  let hdrLen = sizeofSFrameHeaderFixed() + int(hdr.auxHdrLen)
  if bytes.len < hdrLen:
    raise newException(ValueError, "Bytes shorter than header length")
  # Locate subsections relative to end of header
  let fdeStart = hdrLen + int(hdr.fdeOff)
  let fdeLen = int(hdr.numFdes) * sizeofSFrameFDE()
  let freStart = hdrLen + int(hdr.freOff)
  let freLen = int(hdr.freLen)
  if bytes.len < freStart + freLen:
    raise newException(ValueError, "Bytes shorter than sections")

  # Decode FDEs
  var fdes: seq[SFrameFDE] = newSeq[SFrameFDE](int(hdr.numFdes))
  var i = fdeStart
  for idx in 0 ..< int(hdr.numFdes):
    fdes[idx] = decodeFDE(bytes[i ..< i+20])
    i += 20

  # Decode FREs per FDE using start offsets
  var fres: seq[SFrameFRE] = @[]
  for fde in fdes:
    let ft = fde.funcInfo.fdeInfoGetFreType()
    var j = freStart + int(fde.funcStartFreOff)
    for _ in 0 ..< int(fde.funcNumFres):
      let (fr, used) = decodeFRE(bytes[j ..< freStart+freLen], ft)
      fres.add fr
      j += used
  # Sanity on count
  if fres.len != int(hdr.numFres):
    raise newException(ValueError, fmt"Decoded fres {fres.len} != header numFres {hdr.numFres}")
  SFrameSection(header: hdr, fdes: fdes, fres: fres)

# ---- Validation ----

proc validateSection*(sec: SFrameSection; sectionBase: uint64 = 0'u64; checkSorted: bool = false): seq[string] =
  ## Return a list of validation errors; empty if valid.
  var errs: seq[string] = @[]
  let h = sec.header
  if not h.preamble.isValid():
    errs.add "Invalid preamble magic/version"
  if int(h.numFdes) != sec.fdes.len:
    errs.add fmt"Header numFdes={h.numFdes} but fdes.len={sec.fdes.len}"
  var sumFres = 0
  for f in sec.fdes: sumFres += int(f.funcNumFres)
  if int(h.numFres) != sumFres or sec.fres.len != sumFres:
    errs.add fmt"Header numFres={h.numFres}, sumFres={sumFres}, fres.len={sec.fres.len}"
  # Per-function checks
  var freIdx = 0
  for i, fde in sec.fdes:
    if fde.funcInfo.fdeInfoGetFdeType() == sframeFdePcMask and fde.funcRepSize == 0:
      errs.add fmt"FDE[{i}] PCMASK rep_size is 0"
    # Check FRE start addresses are non-decreasing
    var lastSa: uint32 = 0
    for j in 0 ..< int(fde.funcNumFres):
      let fre = sec.fres[freIdx + j]
      if j > 0 and fre.startAddr < lastSa:
        errs.add fmt"FDE[{i}] FRE[{j}] startAddr not sorted"
      lastSa = fre.startAddr
    freIdx += int(fde.funcNumFres)
  if checkSorted and SFrameFlags(h.preamble.flags).hasFlag(SFRAME_F_FDE_SORTED):
    # Verify function starts are sorted w.r.t. provided sectionBase
    var last: uint64 = 0
    for i in 0 ..< sec.fdes.len:
      let start = sec.funcStartAddress(i, sectionBase)
      if i > 0 and start < last:
        errs.add fmt"FDE start addresses not sorted at index {i}"
      last = start
  errs

# Note: Example stack walking utilities moved to separate module `sframe_walk`.
