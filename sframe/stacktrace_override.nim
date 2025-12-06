import std/[os, osproc, strutils, strformat, options]
import sframe
import sframe/amd64_walk

# Optional Nim stacktraces module import for registration symbols
when defined(nimStackTraceOverride) and defined(nimHasStacktracesModule):
  import system/stacktraces

proc getProgramCountersOverride*(
    maxLength: cint
): seq[cuintptr_t] {.nimcall, gcsafe, raises: [], tags: [], noinline.} =
  let frames = captureStackTrace(maxLength)
  var resultFrames = newSeq[cuintptr_t](frames.len)
  for i, frame in frames:
    resultFrames[i] = cast[cuintptr_t](frame)
  return resultFrames

#let pc: StackTraceOverrideGetProgramCountersProc* = proc (maxLength: cint): seq[cuintptr_t] {. nimcall, gcsafe, raises: [], tags: [], noinline.}
 
proc getBacktrace*(): string {.noinline, gcsafe, raises: [], tags: [].} =
  {.cast(gcsafe).}:
    let frames = captureStackTrace()
    var s = ""
    for frame in frames:
      s.add(fmt"0x{frame.toHex()}\n")
    return s

proc getDebuggingInfo*(programCounters: seq[cuintptr_t], maxLength: cint): seq[StackTraceEntry]
    {.noinline, gcsafe, raises: [], tags: [].} =
  {.cast(gcsafe).}:
    echo "GET_DEBUGGING_INFO!!"
    var frames: seq[uint64] = @[]
    for pc in programCounters:
      frames.add cast[uint64](pc)

    # Ensure we don't exceed maxLength if it's specified
    if maxLength > 0 and frames.len > maxLength:
      frames.setLen(maxLength)

    let symbols = symbolizeStackTrace(frames, gFuncSymbols)

    var resultEntries: seq[StackTraceEntry] = @[]
    for sym in symbols:
      var entry: StackTraceEntry
      entry.procname = sym
      resultEntries.add(entry)
    return resultEntries

when defined(nimStackTraceOverride):
  when declared(registerStackTraceOverrideGetProgramCounters):
    registerStackTraceOverrideGetProgramCounters(getProgramCountersOverride)
  when declared(registerStackTraceOverride):
    registerStackTraceOverride(getBacktrace)
  when declared(registerStackTraceOverrideGetDebuggingInfo):
    registerStackTraceOverrideGetDebuggingInfo(getDebuggingInfo)
