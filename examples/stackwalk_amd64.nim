import std/[os, osproc, strutils, strformat, sequtils, options]
import sframe
import sframe/amd64_walk

## NOTE: requires binutils 2.44+ (?)
##
when defined(gcc) or true:
  {.emit: """
  static inline void* nframe_get_fp(void) { return __builtin_frame_address(0); }
  static inline void* nframe_get_ra(void) { return __builtin_return_address(0); }
  static inline void* nframe_get_fp_n(int n) { return __builtin_frame_address(n); }
  static inline void* nframe_get_ra_n(int n) { return __builtin_return_address(n); }
  static inline void* nframe_get_sp(void) {
    void* sp;
#if defined(__x86_64__) || defined(__amd64__)
    __asm__ __volatile__("mov %%rsp, %0" : "=r"(sp));
#elif defined(__aarch64__)
    __asm__ __volatile__("mov %0, sp" : "=r"(sp));
#else
    sp = __builtin_frame_address(0);
#endif
    return sp;
  }
  """.}
  proc nframe_get_fp(): pointer {.importc.}
  proc nframe_get_ra(): pointer {.importc.}
  proc nframe_get_fp_n(n: cint): pointer {.importc.}
  proc nframe_get_ra_n(n: cint): pointer {.importc.}
  proc nframe_get_sp(): pointer {.importc.}

proc getSframeBase(exe: string): uint64 =
  let objdump = "/usr/local/bin/x86_64-unknown-freebsd15.0-objdump"
  let hdr = execProcess(objdump & " -h " & exe)
  for line in hdr.splitLines():
    if line.contains(" .sframe ") or (line.contains(".sframe") and line.contains("VMA")):
      # expect: " 16 .sframe       00000073  0000000000400680 ..."
      let parts = line.splitWhitespace()
      if parts.len >= 4:
        return parseHexInt(parts[3]).uint64
  return 0'u64

proc readU64Ptr(address: uint64): uint64 =
  cast[ptr uint64](cast[pointer](address))[]

proc isValidCodePointer(pc: uint64): bool =
  # Basic heuristic: code addresses should be in a reasonable range
  # and not look like stack addresses
  pc >= 0x400000'u64 and pc < 0x800000'u64

proc dumpStackMemory(sp: uint64, size: int = 128) =
  echo fmt"Stack dump from SP 0x{sp.toHex()}:"
  for i in 0 ..< size div 8:
    let address = sp + uint64(i * 8)
    let val = readU64Ptr(address)
    let marker = if isValidCodePointer(val): " <-- CODE" else: ""
    echo fmt"  +{i*8:3}: 0x{address.toHex()} = 0x{val.toHex()}{marker}"

proc scanStackForReturnAddresses(startSp: uint64; currentPc: uint64; maxScan: int = 2048): seq[tuple[offset: int, pc: uint64]] =
  ## Scan stack memory looking for potential return addresses
  var results: seq[tuple[offset: int, pc: uint64]] = @[]
  for i in 0 ..< maxScan div 8:
    let address = startSp + uint64(i * 8)
    let val = readU64Ptr(address)
    # Look for valid code pointers that are different from current PC
    if isValidCodePointer(val) and val != currentPc:
      results.add((i * 8, val))
  result = results

proc walkStackWithHybridApproach(sec: SFrameSection; sectionBase, startPc, startSp, startFp: uint64; readU64: U64Reader; maxFrames: int = 16): seq[uint64] {.raises: [], tags: [].} =
  ## Hybrid stack walker that combines SFrame data with stack scanning for -fomit-frame-pointer
  var frames: seq[uint64] = @[startPc]

  # First, scan the stack to find potential return addresses
  let stackRAs = scanStackForReturnAddresses(startSp, startPc, 1024)

  if stackRAs.len == 0:
    echo "No potential return addresses found in stack"
    return frames

  # Find potential return addresses by scanning stack memory

  # For each potential return address, validate using SFrame data
  var currentSp = startSp
  for (offset, candidatePc) in stackRAs:
    if frames.len >= maxFrames: break

    # Check if this PC has SFrame data
    let (found, fdeIdx, freLocalIdx, freGlobalIdx) = sec.pcToFre(candidatePc, sectionBase)
    if found:
      # Validate that this is a reasonable next frame
      let funcStart = sec.funcStartAddress(fdeIdx, sectionBase)
      let fde = sec.fdes[fdeIdx]

      # If this looks like a valid caller, add it and search for deeper frames
      if candidatePc > funcStart and candidatePc < (funcStart + uint64(fde.funcSize)):
        frames.add candidatePc
        currentSp = startSp + uint64(offset + 8)  # Move past this return address

        # Recursively search for more frames from this new stack position
        let remainingRAs = scanStackForReturnAddresses(currentSp, candidatePc, 1024)
        for (nextOffset, nextPc) in remainingRAs:
          if frames.len >= maxFrames: break
          let (nextFound, nextFdeIdx, _, _) = sec.pcToFre(nextPc, sectionBase)
          if nextFound:
            let nextFuncStart = sec.funcStartAddress(nextFdeIdx, sectionBase)
            let nextFde = sec.fdes[nextFdeIdx]
            if nextPc > nextFuncStart and nextPc < (nextFuncStart + uint64(nextFde.funcSize)):
              frames.add nextPc
              currentSp += uint64(nextOffset + 8)
        break

  result = frames

proc walkStackAmd64WithFallback(sec: SFrameSection; sectionBase, startPc, startSp, startFp: uint64; readU64: U64Reader; maxFrames: int = 16): seq[uint64] {.raises: [], tags: [].} =
  ## AMD64 stack walker with fallback from FP to SP base for -fomit-frame-pointer scenarios.
  var pc = startPc
  var sp = startSp
  var fp = startFp
  var frames: seq[uint64] = @[]
  for _ in 0 ..< maxFrames:
    frames.add pc
    let (found, _, _, freGlobalIdx) = sec.pcToFre(pc, sectionBase)
    if not found:
      # Fall back to hybrid approach for the rest
      let hybridFrames = walkStackWithHybridApproach(sec, sectionBase, pc, sp, fp, readU64, maxFrames - frames.len)
      for i in 1 ..< hybridFrames.len:  # Skip first frame as it's already in our frames
        frames.add hybridFrames[i]
      break

    let fre = sec.fres[freGlobalIdx]
    var off = freOffsetsForAbi(sframeAbiAmd64Little, sec.header, fre)

    # First try the original CFA calculation
    let originalCfaBase = off.cfaBase
    var baseVal = if off.cfaBase == sframeCfaBaseSp: sp else: fp
    var cfa = baseVal + uint64(cast[int64](off.cfaFromBase))
    if off.raFromCfa.isNone(): break
    let raAddr = cfa + uint64(cast[int64](off.raFromCfa.get()))
    var nextPc = readU64(raAddr)

    # If the result doesn't look like a valid code pointer and we used FP base,
    # fall back to hybrid approach (common with -fomit-frame-pointer)
    if not isValidCodePointer(nextPc) and originalCfaBase == sframeCfaBaseFp:
      let hybridFrames = walkStackWithHybridApproach(sec, sectionBase, pc, sp, fp, readU64, maxFrames - frames.len)
      for i in 1 ..< hybridFrames.len:  # Skip first frame as it's already in our frames
        frames.add hybridFrames[i]
      break

    if nextPc == 0'u64 or not isValidCodePointer(nextPc):
      # Continue with hybrid approach for remaining frames
      let hybridFrames = walkStackWithHybridApproach(sec, sectionBase, pc, sp, fp, readU64, maxFrames - frames.len)
      for i in 1 ..< hybridFrames.len:  # Skip first frame as it's already in our frames
        frames.add hybridFrames[i]
      break

    var nextFp = fp
    if off.fpFromCfa.isSome():
      let fpAddr = cfa + uint64(cast[int64](off.fpFromCfa.get()))
      nextFp = readU64(fpAddr)

    pc = nextPc
    sp = cfa
    fp = nextFp
  result = frames

proc buildFramesFrom(startPc, startSp, startFp: uint64): seq[uint64] =
  let exe = getAppFilename()
  # Work on a temp copy to avoid Text file busy issues with objcopy on running binary
  let exeCopy = getTempDir() / "self.copy"
  try: discard existsOrCreateDir(getTempDir()) except: discard
  try:
    copyFile(exe, exeCopy)
  except CatchableError:
    discard
  # Extract .sframe to a temp path
  let tmp = getTempDir() / "self.out.sframe"
  let objcopy = "/usr/local/bin/x86_64-unknown-freebsd15.0-objcopy"
  let cmd = objcopy & " --dump-section .sframe=" & tmp & " " & exeCopy
  discard execShellCmd(cmd)
  let sdata = readFile(tmp)
  var bytes = newSeq[byte](sdata.len)
  for i in 0 ..< sdata.len: bytes[i] = byte(sdata[i])
  let sec = decodeSection(bytes)
  let sectionBase = getSframeBase(exeCopy)

  # For -fomit-frame-pointer case, we need to handle the case where SFrame data
  # still references FP base but FP is not actually available. We'll use a custom
  # walker that can fall back from FP to SP-based calculation.
  walkStackAmd64WithFallback(sec, sectionBase, startPc, startSp, startFp, readU64Ptr, maxFrames = 16)

proc buildFrames(): seq[uint64] =
  # Capture current frame state and walk (starting at caller of this function)
  var local = 0
  let sp = cast[uint64](addr local)
  let fp = cast[uint64](nframe_get_fp())
  let pc = cast[uint64](nframe_get_ra())
  buildFramesFrom(pc, sp, fp)

var lastFrames: seq[uint64] = @[]

proc nframe_entry_build*() =
  # Start from the immediate caller of this function.
  # Note: This example demonstrates SFrame parsing but may not work perfectly with
  # -fomit-frame-pointer due to GCC still generating FP-centric SFrame data.
  let fp0 = cast[uint64](nframe_get_fp())
  let sp0 = cast[uint64](nframe_get_sp())
  let pc0 = cast[uint64](nframe_get_ra())
  echo fmt"Starting stack trace from PC: 0x{pc0.toHex()} SP: 0x{sp0.toHex()} FP: 0x{fp0.toHex()}"

  # Load and parse SFrame section
  let exe = getAppFilename()
  let exeCopy = getTempDir() / "self.copy"
  try: discard existsOrCreateDir(getTempDir()) except: discard
  try: copyFile(exe, exeCopy) except: discard
  let tmp = getTempDir() / "self.out.sframe"
  let objcopy = "/usr/local/bin/x86_64-unknown-freebsd15.0-objcopy"
  let cmd = objcopy & " --dump-section .sframe=" & tmp & " " & exeCopy
  discard execShellCmd(cmd)
  let sdata = readFile(tmp)
  var bytes = newSeq[byte](sdata.len)
  for i in 0 ..< sdata.len: bytes[i] = byte(sdata[i])
  let sec = decodeSection(bytes)
  let sectionBase = getSframeBase(exeCopy)

  echo fmt"SFrame section: base=0x{sectionBase.toHex()}, {sec.fdes.len} functions, {sec.fres.len} frame entries"
  echo fmt"Header: RA offset={sec.header.cfaFixedRaOffset}, FP offset={sec.header.cfaFixedFpOffset}"

  # Show SFrame data for current PC
  let (found, fdeIdx, freLocalIdx, freGlobalIdx) = sec.pcToFre(pc0, sectionBase)
  if found:
    let fde = sec.fdes[fdeIdx]
    let fre = sec.fres[freGlobalIdx]
    let off = freOffsetsForAbi(sframeAbiAmd64Little, sec.header, fre)
    echo fmt"Found FDE[{fdeIdx}]: function 0x{sec.funcStartAddress(fdeIdx, sectionBase).toHex()}"
    echo fmt"Found FRE[{freLocalIdx}]: CFA base={off.cfaBase}, offset={off.cfaFromBase}"
    let raInfo = if off.raFromCfa.isSome(): $off.raFromCfa.get() else: "fixed"
    let fpInfo = if off.fpFromCfa.isSome(): $off.fpFromCfa.get() else: "none"
    echo fmt"RA recovery: {raInfo}"
    echo fmt"FP recovery: {fpInfo}"
  else:
    echo "No SFrame data found for current PC"

  # Stack layout analysis complete, now attempt stack walking

  lastFrames = buildFramesFrom(pc0, sp0, fp0)

# Force functions to not be inlined and add some computation to prevent optimization
proc deep0() {.noinline.} =
  var x = 0
  for i in 0 ..< 10: x += i
  if x > 0: nframe_entry_build()

proc deep1() {.noinline.} =
  var x = 0
  for i in 0 ..< 10: x += i
  if x > 0: deep0()

proc deep2() {.noinline.} =
  var x = 0
  for i in 0 ..< 10: x += i
  if x > 0: deep1()

proc deep3() {.noinline.} =
  var x = 0
  for i in 0 ..< 10: x += i
  if x > 0: deep2()

proc deep4() {.noinline.} =
  var x = 0
  for i in 0 ..< 10: x += i
  if x > 0: deep3()

proc deep5() {.noinline.} =
  var x = 0
  for i in 0 ..< 10: x += i
  if x > 0: deep4()

proc deep6() {.noinline.} =
  var x = 0
  for i in 0 ..< 10: x += i
  if x > 0: deep5()

proc deep7() {.noinline.} =
  var x = 0
  for i in 0 ..< 10: x += i
  if x > 0: deep6()


when isMainModule:
  echo "SFrame Stack Walking Example"
  echo "============================"
  echo "This example demonstrates parsing SFrame sections and attempting stack walks."
  echo "Note: With -fomit-frame-pointer, GCC may still generate FP-centric SFrame data"
  echo "which limits the effectiveness of the stack walk in some cases."
  echo ""

  # Test with the full deep call stack to see more frames
  deep7()
  let frames = lastFrames
  echo "Stack trace (top->bottom):"
  for i, pc in frames:
    echo fmt"  {i:>2}: 0x{pc.toHex.toLowerAscii()}"
  # Symbolize via addr2line
  let exe = getAppFilename()
  let addr2 = "/usr/local/bin/x86_64-unknown-freebsd15.0-addr2line"
  let addrArgs = frames.mapIt("0x" & it.toHex.toLowerAscii()).join(" ")
  let cmd = addr2 & " -e " & exe & " -f -C -p " & addrArgs
  try:
    let sym = execProcess(cmd)
    let lines = sym.splitLines().filterIt(it.len > 0)
    echo "Symbols:"
    for i, line in lines:
      echo fmt"  {i:>2}: {line}"
  except CatchableError as e:
    echo "addr2line failed: ", e.msg
