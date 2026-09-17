import binny/native_dynlib/build
import std/os

let fixture = currentSourcePath.parentDir

var config = initNativeDynlibBuildConfig(
  fixture / "application/producer.nim",
  "libopaque",
  buildRoot = fixture / "cache",
  bindingsPath = fixture / "opaque_abi.nim",
  exportConfigPath = fixture / "exports.json",
)
config.nimArgs = @["--mm:arc", "-d:useMalloc", "--noNimblePath"]
when defined(opaqueOrcProducer):
  config.nimArgs[0] = "--mm:orc"
when defined(release):
  config.nimArgs.add "-d:release"
when defined(addressSanitizer):
  config.nimArgs.add [
    "-d:noSignalHandler", "--passC:-fsanitize=address -fno-omit-frame-pointer -g",
    "--passL:-fsanitize=address",
  ]
  config.linkerArgs.add "-fsanitize=address"

task opaque, "Build opaque fixture":
  config.buildNativeDynlibAndBindings()
