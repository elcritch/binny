import std/[strformat]
import std/options

import ./types

proc encodePreamble*(pre: SFramePreamble): array[4, byte] =
  ## Encode preamble to bytes using the host CPU endianness for the magic field
  var buf: array[4, byte]
  var i = 0
  when system.cpuEndian == littleEndian:
    putU16LE(buf, i, pre.magic)
  else:
    putU16BE(buf, i, pre.magic)
  buf[i] = byte(pre.version); inc i
  buf[i] = byte(pre.flags); inc i
  buf

proc decodePreamble*(bytes: openArray[byte]): SFramePreamble =
  ## Decode a 4-byte preamble from the given bytes using host CPU endianness
  if bytes.len < 4:
    raise newException(ValueError, fmt"SFrame preamble requires 4 bytes, got {bytes.len}")
  var i = 0
  var m: uint16
  when system.cpuEndian == littleEndian:
    m = getU16LE(bytes, i)
  else:
    m = getU16BE(bytes, i)
  let ver = uint8(bytes[i]); inc i
  let flg = uint8(bytes[i]); inc i
  SFramePreamble(magic: m, version: ver, flags: flg)

proc encodeHeader*(h: SFrameHeader): seq[byte] =
  ## Encode the fixed header (28 bytes) followed by aux header bytes.
  var buf = newSeq[byte](sizeofSFrameHeaderFixed() + int(h.auxHdrLen))
  var i = 0
  # preamble
  let pre = encodePreamble(h.preamble)
  for b in pre:
    buf[i] = b; inc i
  # scalars
  buf[i] = byte(h.abiArch); inc i
  buf[i] = cast[byte](h.cfaFixedFpOffset); inc i
  buf[i] = cast[byte](h.cfaFixedRaOffset); inc i
  buf[i] = byte(h.auxHdrLen); inc i
  when system.cpuEndian == littleEndian:
    putU32LE(buf, i, h.numFdes)
    putU32LE(buf, i, h.numFres)
    putU32LE(buf, i, h.freLen)
    putU32LE(buf, i, h.fdeOff)
    putU32LE(buf, i, h.freOff)
  else:
    putU32BE(buf, i, h.numFdes)
    putU32BE(buf, i, h.numFres)
    putU32BE(buf, i, h.freLen)
    putU32BE(buf, i, h.fdeOff)
    putU32BE(buf, i, h.freOff)
  # aux data
  if h.auxData.len != int(h.auxHdrLen):
    raise newException(ValueError, fmt"auxHdrLen={h.auxHdrLen} but auxData.len={h.auxData.len}")
  for b in h.auxData:
    buf[i] = b; inc i
  result = buf

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
    h.numFdes = getU32LE(bytes, i)
    h.numFres = getU32LE(bytes, i)
    h.freLen = getU32LE(bytes, i)
    h.fdeOff = getU32LE(bytes, i)
    h.freOff = getU32LE(bytes, i)
  else:
    h.numFdes = getU32BE(bytes, i)
    h.numFres = getU32BE(bytes, i)
    h.freLen = getU32BE(bytes, i)
    h.fdeOff = getU32BE(bytes, i)
    h.freOff = getU32BE(bytes, i)
  let auxLen = int(h.auxHdrLen)
  if bytes.len < sizeofSFrameHeaderFixed() + auxLen:
    raise newException(ValueError, "Insufficient bytes for aux header")
  if auxLen > 0:
    h.auxData = @bytes[i ..< i+auxLen]
    i += auxLen
  result = h

proc encodeFDE*(fde: SFrameFDE): array[20, byte] =
  var buf: array[20, byte]
  var i = 0
  when system.cpuEndian == littleEndian:
    putI32LE(buf, i, fde.funcStartAddress)
    putU32LE(buf, i, fde.funcSize)
    putU32LE(buf, i, fde.funcStartFreOff)
    putU32LE(buf, i, fde.funcNumFres)
  else:
    putI32BE(buf, i, fde.funcStartAddress)
    putU32BE(buf, i, fde.funcSize)
    putU32BE(buf, i, fde.funcStartFreOff)
    putU32BE(buf, i, fde.funcNumFres)
  buf[i] = uint8(fde.funcInfo); inc i
  buf[i] = fde.funcRepSize; inc i
  when system.cpuEndian == littleEndian:
    putU16LE(buf, i, fde.funcPadding2)
  else:
    putU16BE(buf, i, fde.funcPadding2)
  buf

proc decodeFDE*(bytes: openArray[byte]): SFrameFDE =
  if bytes.len < 20:
    raise newException(ValueError, fmt"FDE requires 20 bytes, got {bytes.len}")
  var i = 0
  var f: SFrameFDE
  when system.cpuEndian == littleEndian:
    f.funcStartAddress = getI32LE(bytes, i)
    f.funcSize = getU32LE(bytes, i)
    f.funcStartFreOff = getU32LE(bytes, i)
    f.funcNumFres = getU32LE(bytes, i)
  else:
    f.funcStartAddress = getI32BE(bytes, i)
    f.funcSize = getU32BE(bytes, i)
    f.funcStartFreOff = getU32BE(bytes, i)
    f.funcNumFres = getU32BE(bytes, i)
  f.funcInfo = SFrameFdeInfo(bytes[i]); inc i
  f.funcRepSize = bytes[i]; inc i
  when system.cpuEndian == littleEndian:
    f.funcPadding2 = getU16LE(bytes, i)
  else:
    f.funcPadding2 = getU16BE(bytes, i)
  result = f


proc encodeFRE*(fre: SFrameFRE; freType: SFrameFreType): seq[byte] =
  ## Encode a FRE with given startAddr width.
  let offByteSize = fre.info.freInfoOffsetByteSize()
  let n = fre.info.freInfoGetOffsetCount()
  if n != fre.offsets.len:
    raise newException(ValueError, fmt"offset_count={n} but offsets.len={fre.offsets.len}")
  var headLen = 1 # info byte
  case freType
  of sframeFreAddr1: headLen.inc 1
  of sframeFreAddr2: headLen.inc 2
  of sframeFreAddr4: headLen.inc 4
  var buf = newSeq[byte](headLen + n * offByteSize)
  var i = 0
  # start address
  case freType
  of sframeFreAddr1:
    buf[i] = byte(fre.startAddr and 0xFF); inc i
  of sframeFreAddr2:
    when system.cpuEndian == littleEndian:
      putU16LE(buf, i, uint16(fre.startAddr and 0xFFFF))
    else:
      putU16BE(buf, i, uint16(fre.startAddr and 0xFFFF))
  of sframeFreAddr4:
    when system.cpuEndian == littleEndian:
      putU32LE(buf, i, uint32(fre.startAddr))
    else:
      putU32BE(buf, i, uint32(fre.startAddr))
  # info
  buf[i] = uint8(fre.info); inc i
  # offsets
  for k in 0 ..< n:
    let v = fre.offsets[k]
    case offByteSize
    of 1:
      buf[i] = cast[uint8](cast[int8](v)); inc i
    of 2:
      when system.cpuEndian == littleEndian:
        putU16LE(buf, i, cast[uint16](cast[int16](v)))
      else:
        putU16BE(buf, i, cast[uint16](cast[int16](v)))
    of 4:
      when system.cpuEndian == littleEndian:
        putI32LE(buf, i, cast[int32](v))
      else:
        putI32BE(buf, i, cast[int32](v))
    else:
      discard
  result = buf

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
      start = uint32(getU16LE(bytes, i))
    else:
      start = uint32(getU16BE(bytes, i))
  of sframeFreAddr4:
    if bytes.len < 4 + 1: raise newException(ValueError, "Insufficient bytes for FRE addr4")
    when system.cpuEndian == littleEndian:
      start = getU32LE(bytes, i)
    else:
      start = getU32BE(bytes, i)
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
        u = getU16LE(bytes, i)
      else:
        u = getU16BE(bytes, i)
      offs[k] = int32(cast[int16](u))
    of 4:
      var v: int32
      when system.cpuEndian == littleEndian:
        v = getI32LE(bytes, i)
      else:
        v = getI32BE(bytes, i)
      offs[k] = int32(v)
    else:
      discard
  (SFrameFRE(startAddr: start, info: info, offsets: offs), i)

proc encodeSection*(sec: var SFrameSection): seq[byte] =
  ## Encode a complete SFrame section. Updates header and fdes offsets/counts.
  # Validate header
  if sec.header.auxData.len != int(sec.header.auxHdrLen):
    raise newException(ValueError, fmt"auxHdrLen={sec.header.auxHdrLen} but auxData.len={sec.header.auxData.len}")
  let numFdes = sec.fdes.len
  var sumFres = 0
  for f in sec.fdes: sumFres += int(f.funcNumFres)
  if sumFres != sec.fres.len:
    raise newException(ValueError, fmt"Sum of funcNumFres ({sumFres}) != fres.len ({sec.fres.len})")

  # Prepare FRE bytes and per-function starting offsets
  var freBytes: seq[byte] = @[]
  var freStartOffsets = newSeq[uint32](numFdes)
  var freIdx = 0
  for fi, fde in sec.fdes:
    freStartOffsets[fi] = uint32(freBytes.len)
    let ft = fde.funcInfo.fdeInfoGetFreType()
    for _ in 0 ..< int(fde.funcNumFres):
      let fre = sec.fres[freIdx]
      inc freIdx
      let b = encodeFRE(fre, ft)
      freBytes.add b
  # FDE array length
  let fdeArrayLen = numFdes * sizeofSFrameFDE()

  # Build adjusted fdes with computed fre offsets
  var fdeBytes: seq[byte] = newSeq[byte](fdeArrayLen)
  var bi = 0
  var adjustedFdes = newSeq[SFrameFDE](numFdes)
  for i, fde in sec.fdes:
    var f = fde
    f.funcStartFreOff = freStartOffsets[i] # relative to start of FRE sub-section
    adjustedFdes[i] = f
    let enc = encodeFDE(f)
    for b in enc: fdeBytes[bi] = b; inc bi

  # Update header counts and offsets
  sec.header.numFdes = uint32(numFdes)
  sec.header.numFres = uint32(sec.fres.len)
  sec.header.freLen = uint32(freBytes.len)
  sec.header.fdeOff = 0'u32
  sec.header.freOff = uint32(fdeArrayLen) # contiguous layout

  # Compose final bytes: header + fdes + fres
  let headerBytes = encodeHeader(sec.header)
  result = newSeq[byte](headerBytes.len + fdeBytes.len + freBytes.len)
  var oi = 0
  for b in headerBytes: result[oi] = b; inc oi
  for b in fdeBytes: result[oi] = b; inc oi
  for b in freBytes: result[oi] = b; inc oi
  # Replace fdes with adjusted ones (in case caller inspects later)
  sec.fdes = adjustedFdes

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
