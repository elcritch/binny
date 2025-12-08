import sframe/stacktrace_override
import system/stacktraces
import std/[strformat, strutils]

proc deep0() {.noinline.} =
  # Print stacktrace using Nim's built-in API (overridden to use SFrame)
  echo "Nim getStackTrace() output:"
  echo getStackTrace()
  #var steRaw = getStackTraceEntries()
  #let ste = addDebuggingInfo(steRaw)
  #echo "\nstacktraces: ", $ste
  for i in 1..10:
    echo "i: ", $i

var depthSink {.volatile.}: int

template mkDeep(procName, nextName: untyped) =
  proc procName() {.noinline.} =
    nextName()
    inc depthSink

{.push noinline.}

proc deep1() =
  inc depthSink
  deep0()
  dec depthSink
proc deep2() =
  deep1()
  dec depthSink
proc deep3() =
  deep2()
  dec depthSink
proc deep4() =
  deep3()
  dec depthSink
proc deep5() {.noinline.} =
  inc depthSink
  deep4()
  dec depthSink
proc deep6() =
  deep5()
  dec depthSink
proc deep7() {.noinline.} =
  inc depthSink
  deep6()
  dec depthSink

when isMainModule:
  # This will print our override-derived backtrace
  deep7()
