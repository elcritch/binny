import std/os
import binny/native_dynlib/build

let fixture = currentSourcePath.parentDir

var config = initNativeDynlibBuildConfig(
  fixture / "producer.nim",
  "libexceptions",
  buildRoot = fixture / "cache",
  bindingsPath = fixture / "exceptions_abi.nim",
)
config.nimArgs = @[
  "--exceptions:goto", "--mm:arc", "-d:useMalloc", "--noNimblePath"
]
when defined(exceptionAtomicArc):
  config.nimArgs[1] = "--mm:atomicArc"
when defined(exceptionIncremental):
  config.backend = "ic"
  config.nimArgs.add "-d:exceptionIncremental"
when defined(exceptionWrongMode):
  config.nimArgs[0] = "--exceptions:setjmp"

task exceptions, "Build exception bridge fixture":
  config.buildNativeDynlibAndBindings()
