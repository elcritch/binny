import std/os
import binny/native_dynlib/build

let fixture = currentSourcePath.parentDir

var config = initNativeDynlibBuildConfig(
  fixture / "application/producer.nim",
  "libexceptions",
  buildRoot = fixture / "cache",
  bindingsPath = fixture / "exceptions_abi.nim",
  exportConfigPath = fixture / "exports.json",
)
config.nimArgs = @[
  "--exceptions:goto", "--mm:arc", "-d:useMalloc", "--noNimblePath",
  "--path:" & fixture / "external-packages/arbitrary-layout/src",
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
