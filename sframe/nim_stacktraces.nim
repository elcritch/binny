import std/[os, osproc, strutils, strformat]
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
  proc nframe_get_sp(): pointer {.importc.}

type SFrameCache = object
  loaded: bool
  sec: SFrameSection
  base: uint64

var gCache: SFrameCache

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

proc readU64Ptr(address: uint64): uint64 {.raises: [].} =
  cast[ptr uint64](cast[pointer](address))[]

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

proc ensureCache() =
  {.cast(gcsafe).}:
    if not gCache.loaded:
      let (sec, base) = loadSelfSFrame()
      if sec.header.preamble.isValid():
        gCache.sec = sec
        gCache.base = base
        gCache.loaded = true

proc initSFrameCache*() =
  ## Initialize SFrame cache for the current process (best-effort).
  ## Call this early in program startup to enable SFrame-based overrides.
  ensureCache()

proc buildFramesFrom(startPc, startSp, startFp: uint64; maxFrames: int): seq[uint64] {.raises: [].} =
  if not gCache.loaded:
    return @[]
  result = walkStackAmd64With(gCache.sec, gCache.base, startPc, startSp, startFp, readU64Ptr, maxFrames = maxFrames)

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

proc getProgramCounters*(maxLength: cint): seq[cuintptr_t] {.noinline, gcsafe, raises: [].} =
  ## Return up to maxLength program counters, top->bottom, using SFrame data.
  ## Starts from the immediate caller of this function (RA0) so it works with
  ## -fomit-frame-pointer. Avoids use of __builtin_* with n>0.
  {.cast(gcsafe).}:
    var pcsOut: seq[cuintptr_t] = @[]
    if maxLength <= 0: return pcsOut
    ensureCache()
    if not gCache.loaded:
      return pcsOut
    # Capture current register context and unwind using SFrame
    let sp0 = cast[uint64](nframe_get_sp())
    let fp0 = cast[uint64](nframe_get_fp())
    let pc0 = cast[uint64](nframe_get_ra())
    let frames = buildFramesFrom(pc0, sp0, fp0, maxFrames = maxLength.int)
    for i in 0 ..< min(frames.len, maxLength.int):
      pcsOut.add(cast[cuintptr_t](frames[i]))
    result = pcsOut

proc getBacktrace*(): string {.noinline, gcsafe, raises: [].} =
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

# Optional runtime override registration is disabled on this Nim due to effect tag mismatches.
# Users can still call getBacktrace()/getProgramCounters() directly.
