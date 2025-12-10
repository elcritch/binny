import std/[os, osproc, strutils, strformat, options]

import ./stackwalk

# Optional Nim stacktraces module import for registration symbols
when defined(nimStackTraceOverride) and defined(nimHasStacktracesModule):
  import system/stacktraces

proc getProgramCountersOverride*(
    maxLength: cint
): seq[cuintptr_t] {.nimcall, gcsafe, raises: [], tags: [], noinline.} =
  {.cast(gcsafe).}:
    let frames = captureStackTrace(maxLength + 20)  # Get extra frames to account for skipped ones
    var resultFrames = newSeqOfCap[cuintptr_t](frames.len())
    # Skip the first several frames which are in the stacktrace infrastructure
    # We need to skip: getProgramCountersOverride, captureStackTrace, walkStackWithSFrame,
    # and several more frames in the Nim stacktrace system to get back to the original caller
    let skipFrames = 8  # Increase skip count to get back to original calling context
    for i in skipFrames..<frames.len():
      if resultFrames.len >= maxLength:
        break
      resultFrames.add cast[cuintptr_t](frames[i])
    return resultFrames

#let pc: StackTraceOverrideGetProgramCountersProc* = proc (maxLength: cint): seq[cuintptr_t] {. nimcall, gcsafe, raises: [], tags: [], noinline.}
 
proc getDebuggingInfo*(programCounters: seq[cuintptr_t], maxLength: cint): seq[StackTraceEntry]
    {.noinline, gcsafe, raises: [], tags: [].} =
  {.cast(gcsafe), cast(tags: []).}:
    var frames: seq[uint64] = @[]
    for pc in programCounters:
      frames.add cast[uint64](pc)

    # Ensure we don't exceed maxLength if it's specified
    if maxLength > 0 and frames.len > maxLength:
      frames.setLen(maxLength)

    let symbols = symbolizeStackTrace(frames)

    var resultEntries: seq[StackTraceEntry] = @[]
    for sym in symbols:
      var entry: StackTraceEntry
      entry.procname = sym
      resultEntries.add(entry)
    return resultEntries

proc getBacktrace*(): string {.noinline, gcsafe, raises: [], tags: [].} =
  {.cast(gcsafe), cast(tags: []).}:
    let frames = captureStackTrace()
    let symbols = symbolizeStackTrace(frames)
    for i, sym in symbols:
      if i < frames.len:
        result.add(&"{sym} (at 0x{(frames[i]-1).toHex()})\n")

proc unhandledExceptionOverride(e: ref Exception) {.nimcall, tags: [], raises: [].} =
  {.cast(gcsafe), cast(tags: []).}:
    try:
      stderr.write("")
    except:
      discard

when defined(nimStackTraceOverride):

  system.unhandledExceptionHook = unhandledExceptionOverride

  when declared(registerStackTraceOverrideGetProgramCounters):
    registerStackTraceOverrideGetProgramCounters(getProgramCountersOverride)
  when declared(registerStackTraceOverride):
    registerStackTraceOverride(getBacktrace)
  when declared(registerStackTraceOverrideGetDebuggingInfo):
    registerStackTraceOverrideGetDebuggingInfo(getDebuggingInfo)
