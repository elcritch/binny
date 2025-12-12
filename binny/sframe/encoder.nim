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
  buf[i] = byte(pre.version)
  inc i
  buf[i] = byte(pre.flags)
  inc i
  buf

proc encodeHeader*(h: SFrameHeader): seq[byte] =
  ## Encode the fixed header (28 bytes) followed by aux header bytes.
  var buf = newSeq[byte](sizeofSFrameHeaderFixed() + int(h.auxHdrLen))
  var i = 0
  # preamble
  let pre = encodePreamble(h.preamble)
  for b in pre:
    buf[i] = b
    inc i
  # scalars
  buf[i] = byte(h.abiArch)
  inc i
  buf[i] = cast[byte](h.cfaFixedFpOffset)
  inc i
  buf[i] = cast[byte](h.cfaFixedRaOffset)
  inc i
  buf[i] = byte(h.auxHdrLen)
  inc i
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
    raise newException(
      ValueError, fmt"auxHdrLen={h.auxHdrLen} but auxData.len={h.auxData.len}"
    )
  for b in h.auxData:
    buf[i] = b
    inc i
  result = buf

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
  buf[i] = uint8(fde.funcInfo)
  inc i
  buf[i] = fde.funcRepSize
  inc i
  when system.cpuEndian == littleEndian:
    putU16LE(buf, i, fde.funcPadding2)
  else:
    putU16BE(buf, i, fde.funcPadding2)
  buf

proc encodeFRE*(fre: SFrameFRE, freType: SFrameFreType): seq[byte] =
  ## Encode a FRE with given startAddr width.
  let offByteSize = fre.info.freInfoOffsetByteSize()
  let n = fre.info.freInfoGetOffsetCount()
  if n != fre.offsets.len:
    raise
      newException(ValueError, fmt"offset_count={n} but offsets.len={fre.offsets.len}")
  var headLen = 1 # info byte
  case freType
  of sframeFreAddr1:
    headLen.inc 1
  of sframeFreAddr2:
    headLen.inc 2
  of sframeFreAddr4:
    headLen.inc 4
  var buf = newSeq[byte](headLen + n * offByteSize)
  var i = 0
  # start address
  case freType
  of sframeFreAddr1:
    buf[i] = byte(fre.startAddr and 0xFF)
    inc i
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
  buf[i] = uint8(fre.info)
  inc i
  # offsets
  for k in 0 ..< n:
    let v = fre.offsets[k]
    case offByteSize
    of 1:
      buf[i] = cast[uint8](cast[int8](v))
      inc i
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

proc encodeSection*(sec: var SFrameSection): seq[byte] =
  ## Encode a complete SFrame section. Updates header and fdes offsets/counts.
  # Validate header
  if sec.header.auxData.len != int(sec.header.auxHdrLen):
    raise newException(
      ValueError,
      fmt"auxHdrLen={sec.header.auxHdrLen} but auxData.len={sec.header.auxData.len}",
    )
  let numFdes = sec.fdes.len
  var sumFres = 0
  for f in sec.fdes:
    sumFres += int(f.funcNumFres)
  if sumFres != sec.fres.len:
    raise newException(
      ValueError, fmt"Sum of funcNumFres ({sumFres}) != fres.len ({sec.fres.len})"
    )

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
    for b in enc:
      fdeBytes[bi] = b
      inc bi

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
  for b in headerBytes:
    result[oi] = b
    inc oi
  for b in fdeBytes:
    result[oi] = b
    inc oi
  for b in freBytes:
    result[oi] = b
    inc oi
  # Replace fdes with adjusted ones (in case caller inspects later)
  sec.fdes = adjustedFdes
