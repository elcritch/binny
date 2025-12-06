import std/[os, osproc, strutils, strformat, options]
import sframe
import sframe/amd64_walk

# Optional Nim stacktraces module import for registration symbols
when defined(nimStackTraceOverride) and defined(nimHasStacktracesModule):
  import system/stacktraces

proc getProgramCountersOverride*(
    maxLength: cint
): seq[cuintptr_t] {.nimcall, gcsafe, raises: [], tags: [], noinline.} =
  {.cast(gcsafe).}:
    let frames = captureStackTrace(maxLength)
    var resultFrames = newSeqOfCap[cuintptr_t](frames.len()-8)
    for i in 0..<frames.len():
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

    let symbols = symbolizeStackTrace(frames, gFuncSymbols)

    var resultEntries: seq[StackTraceEntry] = @[]
    for sym in symbols:
      var entry: StackTraceEntry
      entry.procname = sym
      resultEntries.add(entry)
    return resultEntries

proc getBacktrace*(): string {.noinline, gcsafe, raises: [], tags: [].} =
  {.cast(gcsafe), cast(tags: []).}:
    let frames = captureStackTrace()
    let symbols = symbolizeStackTrace(frames, gFuncSymbols)
    for i, sym in symbols:
      if i < frames.len:
        result.add(&"{sym}\n")

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
