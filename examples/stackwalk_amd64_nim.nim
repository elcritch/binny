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

proc deep1() =
  inc depthSink
  deep0()
  dec depthSink
proc deep2() =
  deep1()
  inc depthSink
proc deep3() =
  deep2()
proc deep4() =
  deep3()
proc deep5() {.noinline.} =
  inc depthSink
  deep4()
  inc depthSink
proc deep6() =
  deep5()
  inc depthSink
proc deep7() {.noinline.} =
  deep6()
  inc depthSink

#proc deep1() {.noinline.} = deep0()
#proc deep2() {.noinline.} = deep1()
#proc deep3() {.noinline.} = deep2()
#proc deep4() {.noinline.} = deep3()
#proc deep5() {.noinline.} = deep4()
#proc deep6() {.noinline.} = deep5()
#proc deep7() {.noinline.} = deep6()

when isMainModule:
  # This will print our override-derived backtrace
  deep7()
