import std/[os, osproc, strutils, strformat, options]
import sframe
import sframe/amd64_walk

# Optional Nim stacktraces module import for registration symbols
when defined(nimStackTraceOverride) and defined(nimHasStacktracesModule):
  import system/stacktraces

## Low-level helpers to capture frame/return addresses (GCC/Clang builtins)
when defined(gcc) or true:
  {.emit: """
  static inline void* nframe_get_fp_0(void) { return __builtin_frame_address(0); }
  static inline void* nframe_get_ra_0(void) { return __builtin_return_address(0); }
  static inline void* nframe_get_fp_1(void) { return __builtin_frame_address(1); }
  static inline void* nframe_get_ra_1(void) { return __builtin_return_address(1); }
  static inline void* nframe_get_ip(void) {
    void* ip;
#if defined(__x86_64__) || defined(__amd64__)
    __asm__ __volatile__("leaq (%%rip), %0" : "=r"(ip));
#elif defined(__aarch64__)
    __asm__ __volatile__("adr %0, ." : "=r"(ip));
#else
    ip = __builtin_return_address(0);
#endif
    return ip;
  }
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
  proc nframe_get_fp(): pointer {.importc: "nframe_get_fp_0".}
  proc nframe_get_ra(): pointer {.importc: "nframe_get_ra_0".}
  proc nframe_get_fp_1(): pointer {.importc.}
  proc nframe_get_ra_1(): pointer {.importc.}
  proc nframe_get_ip(): pointer {.importc.}
  proc nframe_get_sp(): pointer {.importc.}

type SFrameCache = object
  loaded: bool
  sec: SFrameSection
  base: uint64

proc chooseTool(cands: openArray[string]): string =
  for p in cands:
    if fileExists(p): return p
  # fallback to first name to allow PATH resolution (may fail at runtime)
  if cands.len > 0: cands[0] else: ""

proc getSframeBase(exe: string): uint64 =
  ## Determine the VMA of the .sframe section using objdump -h output.
  let objdump = chooseTool([
    "/usr/local/bin/x86_64-unknown-freebsd15.0-objdump",
    "/usr/bin/objdump",
    "/usr/local/bin/objdump"
  ])
  if objdump.len == 0: return 0'u64
  try:
    let hdr = execProcess(objdump & " -h " & exe)
    for line in hdr.splitLines():
      if line.contains(" .sframe ") or (line.contains(".sframe") and line.contains("VMA")):
        let parts = line.splitWhitespace()
        if parts.len >= 4:
          return parseHexInt(parts[3]).uint64
  except CatchableError:
    discard
  0'u64

proc readU64Ptr(address: uint64): uint64 {.raises: [], tags: [].} =
  cast[ptr uint64](cast[pointer](address))[]

# Guarded reader to avoid faults when scanning under -fomit-frame-pointer
var gSafeMinAddr: uint64
var gSafeMaxAddr: uint64

proc readU64PtrRanged(address: uint64): uint64 {.gcsafe, raises: [], tags: [].} =
  if address >= gSafeMinAddr and address + 8'u64 <= gSafeMaxAddr:
    cast[ptr uint64](cast[pointer](address))[]
  else:
    0'u64

proc loadSelfSFrame(): (SFrameSection, uint64) =
  ## Extract and decode .sframe from the running executable, and return (section, baseVma).
  let exe = getAppFilename()
  # Work on a temp copy to avoid 'Text file busy' issues
  let exeCopy = getTempDir() / "self.copy"
  try:
    discard existsOrCreateDir(getTempDir())
  except CatchableError:
    discard
  try:
    copyFile(exe, exeCopy)
  except CatchableError:
    # Best effort; if copy fails, try original
    discard

  let objcopy = chooseTool([
    "/usr/local/bin/x86_64-unknown-freebsd15.0-objcopy",
    "/usr/bin/objcopy",
    "/usr/local/bin/objcopy",
    "/usr/bin/llvm-objcopy",
    "/usr/local/bin/llvm-objcopy"
  ])
  let workExe = if fileExists(exeCopy): exeCopy else: exe
  let tmp = getTempDir() / "self.out.sframe"
  if objcopy.len > 0:
    try:
      discard execProcess(objcopy & " --dump-section .sframe=" & tmp & " " & workExe,
                          options = {poEvalCommand, poUsePath, poStdErrToStdOut})
    except CatchableError:
      discard
  var sec: SFrameSection
  var base: uint64 = 0
  try:
    let sdata = readFile(tmp)
    var bytes = newSeq[byte](sdata.len)
    for i in 0 ..< sdata.len:
      bytes[i] = byte(sdata[i])
    sec = decodeSection(bytes)
    base = getSframeBase(workExe)
  except CatchableError:
    discard
  (sec, base)

proc loadSFrameCache(): SFrameCache =
  let (sec, base) = loadSelfSFrame()
  if sec.header.preamble.isValid():
    result.sec = sec
    result.base = base
    result.loaded = true

var gCache: SFrameCache = loadSFrameCache()

proc ensureCache() =
  {.cast(gcsafe).}:
    if not gCache.loaded:
      gCache = loadSFrameCache()

proc buildFramesFrom(startPc, startSp, startFp: uint64; maxFrames: int): seq[uint64] {.raises: [], tags: [].} =
  if not gCache.loaded:
    return @[]
  # Precompute the initial CFA for startPc so we don't duplicate the first frame
  # when startSp/startFp do not match startPc's frame (e.g., omit-frame-pointer).
  var pc = startPc
  var sp = startSp
  var fp = startFp
  block preStep:
    let (found, _, _, freIdx) = gCache.sec.pcToFre(pc, gCache.base)
    if not found: break preStep
    let fre = gCache.sec.fres[freIdx]
    let off = freOffsetsForAbi(sframeAbiAmd64Little, gCache.sec.header, fre)
    let baseVal = if off.cfaBase == sframeCfaBaseSp: sp else: fp
    let cfa = baseVal + uint64(cast[int64](off.cfaFromBase))
    if off.raFromCfa.isNone(): break preStep
    let raAddr = cfa + uint64(cast[int64](off.raFromCfa.get()))
    let nextPc = readU64Ptr(raAddr)
    if nextPc == 0'u64: break preStep
    var nextFp = fp
    if off.fpFromCfa.isSome():
      let fpAddr = cfa + uint64(cast[int64](off.fpFromCfa.get()))
      nextFp = readU64Ptr(fpAddr)
    pc = nextPc
    sp = cfa
    fp = nextFp
  result = walkStackAmd64With(gCache.sec, gCache.base, pc, sp, fp, readU64Ptr, maxFrames = maxFrames)

proc buildCurrentCallerFrames*(maxFrames: int = 32): seq[uint64] {.noinline, gcsafe, raises: [].} =
  ## Capture current frame (this proc) and unwind starting at our caller using SFrame.
  {.cast(gcsafe).}:
    ensureCache()
    if not gCache.loaded:
      return @[]
    let sp0 = cast[uint64](nframe_get_sp())
    let fp0 = cast[uint64](nframe_get_fp())
    let pc0 = cast[uint64](nframe_get_ra())
    buildFramesFrom(pc0, sp0, fp0, maxFrames)

proc buildFrames(maxFrames: int = 32): seq[uint64] =
  # Capture current frame state and walk (starting at caller of this function)
  var local = 0
  let sp = cast[uint64](addr local)
  let fp = cast[uint64](nframe_get_fp())
  let pc = cast[uint64](nframe_get_ra())
  buildFramesFrom(pc, sp, fp, maxFrames)

when not declared(cuintptr_t):
  # On some Nim platforms uintptr_t may map to unsigned long instead of uint
  type cuintptr_t* {.importc: "uintptr_t", nodecl.} = uint

proc getProgramCounters*(maxLength: cint): seq[cuintptr_t] {.noinline, gcsafe, raises: [], tags: [].} =
  ## Return up to maxLength program counters, top->bottom, using SFrame data.
  ## Starts from the immediate caller of this function (RA0) so it works with
  ## -fomit-frame-pointer. Avoids use of __builtin_* with n>0.
  {.cast(gcsafe).}:
    var pcsOut: seq[cuintptr_t] = @[]
    if maxLength <= 0: return pcsOut
    # Expect initSFrameCache() to be called by the application.
    if not gCache.loaded:
      return pcsOut
    # Heuristic: scan the current stack for the first return address that maps
    # to an SFrame-covered function in the main executable, then compute CFA
    # from the RA location and resume a proper SFrame walk from there.
    let spNow = cast[uint64](nframe_get_sp())
    # Restrict raw memory reads to a safe window above current SP to prevent faults
    gSafeMinAddr = spNow
    gSafeMaxAddr = spNow + 1'u64 shl 20 # ~1 MiB scan window
    var startPc: uint64 = 0
    var startSp: uint64 = 0
    var startFp: uint64 = 0
    var foundStart = false
    var k = 0
    const ScanWords = 128
    while k < ScanWords:
      let raLoc = spNow + uint64(k * 8)
      let candPc = readU64Ptr(raLoc)
      if candPc == 0'u64:
        inc k; continue
      let (found, fdeIdx, freLocalIdx, freGlobalIdx) = gCache.sec.pcToFre(candPc, gCache.base)
      if found:
        let fre = gCache.sec.fres[freGlobalIdx]
        let off = freOffsetsForAbi(sframeAbiAmd64Little, gCache.sec.header, fre)
        if off.raFromCfa.isSome():
          let raOff = uint64(cast[int64](off.raFromCfa.get()))
          let cfa = raLoc - raOff
          # Compute the corresponding base register value so that
          #    baseVal + cfaFromBase == cfa
          let cfaFromBase = uint64(cast[int64](off.cfaFromBase))
          if off.cfaBase == sframeCfaBaseSp:
            startSp = cfa - cfaFromBase
            startFp = cast[uint64](nframe_get_fp())
          else:
            startFp = cfa - cfaFromBase
            startSp = spNow
          # Validate by attempting a short unwind from this start using a
          # guarded reader to avoid segfaults when FP is omitted.
          let testFrames = walkStackAmd64With(gCache.sec, gCache.base, candPc, startSp, startFp, readU64PtrRanged, maxFrames = 6)
          if testFrames.len >= 4:
            startPc = candPc
            foundStart = true
            break
      inc k
    if not foundStart:
      # Fallback: attempt to start from our caller's RA (may be inside runtime)
      startPc = cast[uint64](nframe_get_ra())
      startSp = spNow
      startFp = cast[uint64](nframe_get_fp())
    # Perform the actual walk with the guarded reader
    let frames = walkStackAmd64With(gCache.sec, gCache.base, startPc, startSp, startFp, readU64PtrRanged, maxFrames = maxLength.int + 32)
    var skip = 0
    # Skip frames that point into nim_stacktraces (best-effort) by using address
    # range heuristics: prefer PCs in the main executable's lower VA range.
    # If we started from a runtime frame, drop 1 to reach user frame.
    if frames.len > 0 and frames[0] >= 0x0000000800000000'u64:
      skip = 1
    let upto = min(frames.len, skip + maxLength.int)
    var i = skip
    while i < upto:
      pcsOut.add(cast[cuintptr_t](frames[i]))
      inc i
    result = pcsOut

proc getBacktrace*(): string {.noinline, gcsafe, raises: [], tags: [].} =
  {.cast(gcsafe).}:
    ## Return a human-readable backtrace string based on SFrame PCs.
    let pcs = getProgramCounters(64)
    if pcs.len == 0:
      return "(no sframe backtrace available)"
    var lines: seq[string] = @[]
    var i = 0
    for pc in pcs:
      lines.add fmt"  {i:>2}: 0x{cast[uint64](pc).toHex.toLowerAscii()}"
      inc i
    result = lines.join("\n")

# Provide minimal debugging info mapping: wrap PCs into entries.
# Leave filename/procname empty to keep this effect-free; symbolization can
# be done by the application outside the override path if desired.
proc getDebuggingInfo*(programCounters: seq[cuintptr_t], maxLength: cint): seq[StackTraceEntry]
    {.noinline, gcsafe, raises: [], tags: [].} =
  ## Symbolize program counters to (proc, file, line) using addr2line/llvm-addr2line.
  ## Uses the main executable as the object file. Returns up to maxLength entries.
  echo "get debugging info!!!!!"
  var entries: seq[StackTraceEntry] = @[]
  if programCounters.len == 0 or maxLength <= 0: return entries
  let upto = min(programCounters.len, maxLength.int)
  entries.setLen(upto)

  # Effect-free symbolization via dladdr; yields proc name and image path.
  type Dl_info {.importc: "Dl_info", header: "dlfcn.h".} = object
    dli_fname*: cstring
    dli_fbase*: pointer
    dli_sname*: cstring
    dli_saddr*: pointer
  proc dladdr(paddr: pointer, info: ptr Dl_info): int {.importc: "dladdr", header: "dlfcn.h".}

  proc symbolize(pc: uint64): tuple[procname, file: string, line: int] =
    var info: Dl_info
    let res = dladdr(cast[pointer](pc), addr info)
    if res != 0:
      let pn = if info.dli_sname.isNil: "" else: $info.dli_sname
      let fn = if info.dli_fname.isNil: "" else: $info.dli_fname
      (pn, fn, 0)
    else:
      ("", "", 0)

  var i = 0
  while i < upto:
    let pc = cast[uint64](programCounters[i])
    let (pn, fl, ln) = symbolize(pc)
    entries[i] = StackTraceEntry(
      programCounter: cast[uint](pc),
      procname: pn,
      filename: fl,
      line: ln
    )
    inc i
  result = entries

when defined(nimStackTraceOverride):
  when declared(registerStackTraceOverrideGetProgramCounters):
    registerStackTraceOverrideGetProgramCounters(getProgramCounters)
  when declared(registerStackTraceOverride):
    registerStackTraceOverride(getBacktrace)
  when declared(registerStackTraceOverrideGetDebuggingInfo):
    registerStackTraceOverrideGetDebuggingInfo(getDebuggingInfo)
