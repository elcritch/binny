import std/[os, strutils, strformat, sequtils, cmdline]
import sframe

proc parseUint64(s: string): uint64 =
  let v = s.strip()
  if v.len > 2 and (v[0..1] == "0x" or v[0..1] == "0X"):
    result = uint64(fromHex[int64](v[2..^1]))
  else:
    result = parseUInt(v)

proc flagNames(flags: SFrameFlags): seq[string] =
  if flags.hasFlag(SFRAME_F_FDE_SORTED): result.add "FDE_SORTED"
  if flags.hasFlag(SFRAME_F_FRAME_POINTER): result.add "FRAME_POINTER"
  if flags.hasFlag(SFRAME_F_FDE_FUNC_START_PCREL): result.add "FDE_FUNC_START_PCREL"

proc abiName(abi: uint8): string =
  case SFrameAbiArch(abi)
  of sframeAbiAarch64Big: "AARCH64(big)"
  of sframeAbiAarch64Little: "AARCH64(little)"
  of sframeAbiAmd64Little: "AMD64(little)"
  of sframeAbiS390xBig: "s390x(big)"
  else: "unknown"

proc dump(path: string; sectionBase: uint64 = 0) =
  if not fileExists(path):
    quit fmt"File not found: {path}", 1
  let s = readFile(path)
  var bytes = newSeq[byte](s.len)
  for i in 0 ..< s.len: bytes[i] = byte(s[i])

  let sec = decodeSection(bytes)
  let pre = sec.header.preamble
  let flags = SFrameFlags(pre.flags)
  let magicStr = pre.magic.toHex.toLowerAscii()
  let flagsStr = flagNames(flags).join(", ")
  echo fmt"SFrame: magic=0x{magicStr} ver={pre.version} flags=[{flagsStr}]"
  echo fmt"  ABI={abiName(sec.header.abiArch)} auxLen={sec.header.auxHdrLen}"
  echo fmt"  cfaFixedFpOffset={sec.header.cfaFixedFpOffset} cfaFixedRaOffset={sec.header.cfaFixedRaOffset}"
  echo fmt"  fdes={sec.header.numFdes} fres={sec.header.numFres} freLen={sec.header.freLen}"
  echo fmt"  fdeOff={sec.header.fdeOff} freOff={sec.header.freOff}"

  var freIdx = 0
  for i, fde in sec.fdes:
    let fstart = sec.funcStartAddress(i, sectionBase)
    echo fmt"FDE[{i}]: start=0x{fstart.toHex.toLowerAscii()} size=0x{fde.funcSize.toHex.toLowerAscii()} rep={fde.funcRepSize} freType={fde.funcInfo.fdeInfoGetFreType()} fdeType={fde.funcInfo.fdeInfoGetFdeType()} startFreOff={fde.funcStartFreOff} numFres={fde.funcNumFres}"
    # Dump FREs for this function
    let n = int(fde.funcNumFres)
    for j in 0 ..< min(n, 8):
      let fre = sec.fres[freIdx + j]
      let info = fre.info
      let cfaBase = info.freInfoGetCfaBase()
      let offCount = info.freInfoGetOffsetCount()
      let offSize = info.freInfoOffsetByteSize()
      echo fmt"  FRE[{j}]: startOff=0x{fre.startAddr.toHex.toLowerAscii()} cfaBase={cfaBase} offsets={offCount}×{offSize}B"
      if fre.offsets.len > 0:
        let offs = fre.offsets.mapIt($it).join(", ")
        echo fmt"    offs: [{offs}]"
    freIdx += n

when isMainModule:
  var base: uint64 = 0
  var filePath = ""
  for a in commandLineParams():
    if a.startsWith("--base="):
      base = parseUint64(a.split("=", 1)[1])
    elif filePath.len == 0:
      filePath = a
    else:
      discard
  if filePath.len == 0:
    echo "Usage: sframe_dump <sframe.bin> [--base=0xADDR]"
    quit 1
  dump(filePath, base)
