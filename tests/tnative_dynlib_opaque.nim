import std/[assertions, json, os, osproc, sequtils, strutils, tempfiles]
import binny/native_dynlib
import binny/native_dynlib/bifreader
import binny/native_dynlib/staticlib

proc run(arguments: openArray[string]): string =
  var command: seq[string]
  for argument in arguments:
    command.add argument.quoteShell
  let executed = execCmdEx(command.join(" "))
  doAssert executed.exitCode == 0, command.join(" ") & "\n" & executed.output
  executed.output

let compiler = getCurrentCompilerExe()
let help = execCmdEx(compiler.quoteShell & " --fullhelp")
if help.exitCode == 0 and "--genBif:on|off" in help.output and
    fileExists(compiler.parentDir / ("nifler" & ExeExt)):
  let temporary = createTempDir("binny-native-opaque-", "")
  var completed = false
  defer:
    if completed:
      removeDir(temporary)
    else:
      echo "Opaque fixture retained at ", temporary
  copyDir(currentSourcePath.parentDir / "fixtures/native_dynlib_opaque", temporary)
  writeFile(
    temporary / "nim.cfg",
    "--path:" & currentSourcePath.parentDir.parentDir.escape & "\n",
  )
  var flags: seq[string]
  when defined(release):
    flags.add "-d:release"
  when defined(addressSanitizer):
    flags.add [
      "-d:addressSanitizer", "-d:noSignalHandler",
      "--passC:-fsanitize=address -fno-omit-frame-pointer -g",
      "--passL:-fsanitize=address",
    ]
  let source = temporary / "application/producer.nim"
  let cache = temporary / "cache/c/producer"
  discard run(
    @[compiler, "opaque", "--path:" & currentSourcePath.parentDir.parentDir] & flags &
      @[source]
  )
  let generated = readFile(temporary / "opaque_abi.nim")
  doAssert "import " notin generated
  doAssert "graphics" notin generated
  let base =
    @[
      compiler,
      "c",
      "--mm:arc",
      "-d:useMalloc",
      "--noNimblePath",
      "--path:" & currentSourcePath.parentDir.parentDir,
      "--path:" & temporary,
      "--nimcache:" & temporary / "consumer-cache",
      "--out:" & temporary / "consumer",
    ] & flags
  discard run(base & @["-r", temporary / "consumer.nim"])
  for source in parseFile(temporary / "consumer-cache/consumer.json")["compile"]:
    doAssert "backend.nim" notin source[0].getStr
    doAssert "producer.nim" notin source[0].getStr
  # Repeat generation against a warm producer cache.
  discard run(
    @[compiler, "opaque", "--path:" & currentSourcePath.parentDir.parentDir] & flags &
      @[source]
  )
  discard run(base & @["-r", temporary / "consumer.nim"])
  let rejected = execCmdEx(
    (base & @["--mm:orc", temporary / "consumer.nim"]).mapIt(it.quoteShell).join(" ")
  )
  doAssert rejected.exitCode != 0
  doAssert "ORC tracing is not supported" in rejected.output
  var config = loadNativeExportConfig(temporary / "exports.json")
  config.opaqueTypes.add opaqueType("Missing", "producer.nim")
  doAssertRaises NativeStaticLibError:
    discard initBifNativeBindingsConfig(
        source, cache, "libopaque", source.parentDir, config
      )
      .generateNativeBindings()
  config.opaqueTypes = @[opaqueType("NativeState", "backend.nim")]
  doAssertRaises NativeStaticLibError:
    discard readBifNativeApi(cache, source.parentDir, source, "libopaque", config)
  config.opaqueTypes =
    @[opaqueType("NativeState", "producer.nim"), opaqueType("State", "../backend.nim")]
  try:
    discard readBifNativeApi(cache, source.parentDir, source, "libopaque", config)
    doAssert false, "opaque ABI identity collisions must be rejected"
  except NativeBifError as error:
    doAssert "same ABI type" in error.msg
  config.opaqueTypes = @[opaqueType("NativeState", "producer.nim")]
  config.typeImports = @[importType("NativeState", "backend", source = "producer.nim")]
  try:
    discard readBifNativeApi(cache, source.parentDir, source, "libopaque", config)
    doAssert false, "imported/opaque overlap must be rejected"
  except NativeBifError as error:
    doAssert "both imported and opaque" in error.msg
  let rejectedProducer = execCmdEx(
    (
      @[
        compiler,
        "opaque",
        "--path:" & currentSourcePath.parentDir.parentDir,
        "-d:opaqueOrcProducer",
      ] & flags & @[source]
    )
    .mapIt(it.quoteShell)
    .join(" ")
  )
  doAssert rejectedProducer.exitCode != 0
  doAssert "ORC tracing is not supported" in rejectedProducer.output
  completed = true
