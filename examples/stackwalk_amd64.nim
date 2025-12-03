import std/[os, osproc, strutils, strformat]
import sframe
import sframe/amd64_walk

when defined(gcc) or true:
  {.emit: """
  static inline void* nframe_get_fp(void) { return __builtin_frame_address(0); }
  static inline void* nframe_get_ra(void) { return __builtin_return_address(0); }
  """.}
  proc nframe_get_fp(): pointer {.importc.}
  proc nframe_get_ra(): pointer {.importc.}

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

proc buildFrames(): seq[uint64] =
  # Capture current frame state and walk
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
  # starting registers
  var local = 0
  let sp = cast[uint64](addr local)
  let fp = cast[uint64](nframe_get_fp())
  let pc = cast[uint64](nframe_get_ra())
  walkStackAmd64With(sec, sectionBase, pc, sp, fp, readU64Ptr, maxFrames = 16)

proc inner2(): seq[uint64] = buildFrames()
proc inner1(): seq[uint64] = inner2()

when isMainModule:
  let frames = inner1()
  echo "Stack trace PCs (top->bottom):"
  for pc in frames:
    echo fmt"  0x{pc.toHex.toLowerAscii()}"
