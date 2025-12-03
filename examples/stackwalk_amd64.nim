import std/[os, osproc, strutils, strformat, sequtils]
import sframe
import sframe/amd64_walk

when defined(gcc) or true:
  {.emit: """
  static inline void* nframe_get_fp(void) { return __builtin_frame_address(0); }
  static inline void* nframe_get_ra(void) { return __builtin_return_address(0); }
  static inline void* nframe_get_fp_n(int n) { return __builtin_frame_address(n); }
  static inline void* nframe_get_ra_n(int n) { return __builtin_return_address(n); }
  """.}
  proc nframe_get_fp(): pointer {.importc.}
  proc nframe_get_ra(): pointer {.importc.}
  proc nframe_get_fp_n(n: cint): pointer {.importc.}
  proc nframe_get_ra_n(n: cint): pointer {.importc.}

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
  walkStackAmd64With(sec, sectionBase, startPc, startSp, startFp, readU64Ptr, maxFrames = 16)

proc buildFrames(): seq[uint64] =
  # Capture current frame state and walk (starting at caller of this function)
  var local = 0
  let sp = cast[uint64](addr local)
  let fp = cast[uint64](nframe_get_fp())
  let pc = cast[uint64](nframe_get_ra())
  buildFramesFrom(pc, sp, fp)

var lastFrames: seq[uint64] = @[]

proc nframe_entry_build*() =
  # Start from the caller frame (cdeep0): use level-1 frame/return address.
  let fp1 = cast[uint64](nframe_get_fp_n(1))
  let pc1 = cast[uint64](nframe_get_ra_n(1))
  # Use caller FP as an approximation for caller SP base (FRE often uses FP base post-prologue)
  let sp1 = fp1
  lastFrames = buildFramesFrom(pc1, sp1, fp1)

#proc cdeep7() {.importc.}
proc deep0() {.noinline.} = nframe_entry_build()
proc deep1() {.noinline.} = deep0()
proc deep2() {.noinline.} = deep1()
proc deep3() {.noinline.} = deep2()
proc deep4() {.noinline.} = deep3()
proc deep5() {.noinline.} = deep4()
proc deep6() {.noinline.} = deep5()
proc deep7() {.noinline.} = deep6()


when isMainModule:
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
