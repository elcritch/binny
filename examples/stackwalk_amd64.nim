import sframe/amd64_walk

## NOTE: requires binutils 2.44+ (?)
##

var lastFrames: seq[uint64] = @[]

proc deep0() {.noinline.} =
  # Capture stack trace with verbose output for demonstration
  lastFrames = captureStackTrace(maxFrames = 16)
  let frames = lastFrames
  let symbols = symbolizeStackTrace(frames)
  printStackTrace(frames, symbols)

var depthSink {.volatile.}: int

template mkDeep(procName, nextName: untyped) =
  proc procName() {.noinline.} =
    inc depthSink
    nextName()
    dec depthSink

mkDeep(deep1, deep0)
mkDeep(deep2, deep1)
mkDeep(deep3, deep2)
mkDeep(deep4, deep3)
mkDeep(deep5, deep4)
mkDeep(deep6, deep5)
mkDeep(deep7, deep6)


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
