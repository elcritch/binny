import sframe/amd64_walk
import std/[strformat, strutils]

var depthSink {.volatile.}: int

proc deep0() {.noinline.} =
  echo "In deep0, calling walkStackWithSFrame directly"

  # Get raw register values
  var sp, fp, pc: uint64
  {.emit: """
  __asm__ __volatile__("mov %%rsp, %0" : "=r"(`sp`));
  __asm__ __volatile__("mov %%rbp, %0" : "=r"(`fp`));
  __asm__ __volatile__("leaq (%%rip), %0" : "=r"(`pc`));
  """.}

  echo fmt"Raw registers: SP=0x{sp.toHex}, FP=0x{fp.toHex}, PC=0x{pc.toHex}"

  # Check what's at FP and FP+8 (standard x86-64 layout)
  let savedFp = cast[ptr uint64](fp)[]
  let savedRa = cast[ptr uint64](fp + 8)[]
  echo fmt"At FP+0 (saved FP): 0x{savedFp.toHex}"
  echo fmt"At FP+8 (saved RA): 0x{savedRa.toHex}"

  let frames = captureStackTrace(64)
  echo fmt"\nCaptured {frames.len} frames:"
  for i, pc in frames:
    echo fmt"  Frame {i}: PC=0x{pc.toHex}"

  let symbols = symbolizeStackTrace(frames)
  echo "\nSymbolized:"
  for i, sym in symbols:
    echo fmt"  {i}: {sym}"

proc deep1() {.noinline.} =
  inc depthSink
  deep0()
  dec depthSink

proc deep2() {.noinline.} =
  inc depthSink
  deep1()
  dec depthSink

proc deep3() {.noinline.} =
  inc depthSink
  deep2()
  dec depthSink

proc deep4() {.noinline.} =
  inc depthSink
  deep3()
  dec depthSink

proc deep5() {.noinline.} =
  inc depthSink
  deep4()
  dec depthSink

proc deep6() {.noinline.} =
  inc depthSink
  deep5()
  dec depthSink

proc deep7() {.noinline.} =
  inc depthSink
  deep6()
  dec depthSink

when isMainModule:
  echo "Starting deep stack test..."
  deep7()
  echo "\nTest complete!"
