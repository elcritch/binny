import sframe/amd64_walk

## NOTE: requires binutils 2.44+ (?)
##

var lastFrames: seq[uint64] = @[]

proc nframe_entry_build*() =
  # Capture stack trace with verbose output for demonstration
  lastFrames = captureStackTrace(maxFrames = 16)

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
  deep1()

proc deep3() {.noinline.} =
  var x = 0
  for i in 0 ..< 10: x += i
  if x > 0: deep2()

proc deep4() {.noinline.} =
  var x = 0
  for i in 0 ..< 10: x += i
  if x > 0: deep3()

proc deep5() {.noinline.} =
  deep4()

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
  let symbols = symbolizeStackTrace(frames)
  printStackTrace(frames, symbols)
