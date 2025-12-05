import std/[os, osproc, strutils, strformat, sequtils]
import sframe
import sframe/amd64_walk

when defined(gcc) or true:
  {.emit: """
  static inline void* nframe_get_fp(void) { return __builtin_frame_address(0); }
  static inline void* nframe_get_ra(void) { return __builtin_return_address(0); }
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
  proc nframe_get_sp(): pointer {.importc.}

proc getSframeBase(exe: string): uint64 =
  let objdump = "/usr/local/bin/x86_64-unknown-freebsd15.0-objdump"
  let hdr = execProcess(objdump & " -h " & exe)
  for line in hdr.splitLines():
    if line.contains(" .sframe ") or (line.contains(".sframe") and line.contains("VMA")):
      let parts = line.splitWhitespace()
      if parts.len >= 4:
        return parseHexInt(parts[3]).uint64
  return 0'u64

proc readU64Ptr(address: uint64): uint64 =
  cast[ptr uint64](cast[pointer](address))[]

proc buildFramesFrom(startPc, startSp, startFp: uint64): seq[uint64] =
  let exe = getAppFilename()
  let exeCopy = getTempDir() / "self.copy"
  try: discard existsOrCreateDir(getTempDir()) except: discard
  try:
    copyFile(exe, exeCopy)
  except CatchableError:
    discard
  let tmp = getTempDir() / "self.out.sframe"
  let objcopy = "/usr/local/bin/x86_64-unknown-freebsd15.0-objcopy"
  let cmd = objcopy & " --dump-section .sframe=" & tmp & " " & exeCopy
  discard execShellCmd(cmd)
  let sdata = readFile(tmp)
  var bytes = newSeq[byte](sdata.len)
  for i in 0 ..< sdata.len: bytes[i] = byte(sdata[i])
  let sec = decodeSection(bytes)
  let sectionBase = getSframeBase(exeCopy)
  walkStackAmd64With(sec, sectionBase, startPc, startSp, startFp, readU64Ptr, maxFrames = 32)

var lastFrames: seq[uint64] = @[]

proc nframe_entry_build() {.noinline.} =
  let fp0 = cast[uint64](nframe_get_fp())
  let sp0 = cast[uint64](nframe_get_sp())
  let pc0 = cast[uint64](nframe_get_ra())
  lastFrames = buildFramesFrom(pc0, sp0, fp0)

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
