import sframe/nim_stacktraces

proc deep0() {.noinline.} =
  # Print SFrame-derived backtrace via Nim override function
  echo "SFrame backtrace (via override):"
  echo getBacktrace()

proc deep1() {.noinline.} = deep0()
proc deep2() {.noinline.} = deep1()
proc deep3() {.noinline.} = deep2()
proc deep4() {.noinline.} = deep3()
proc deep5() {.noinline.} = deep4()
proc deep6() {.noinline.} = deep5()
proc deep7() {.noinline.} = deep6()

when isMainModule:
  # This will print our override-derived backtrace
  deep7()
