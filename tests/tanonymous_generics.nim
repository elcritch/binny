import std/[assertions, os, osproc, strutils, tempfiles]
import binny/native_dynlib
import binny/native_dynlib/staticlib

proc quoteShell(value: string): string =
  result = "'"
  for character in value:
    if character == '\'':
      result.add "'\"'\"'"
    else:
      result.add character
  result.add "'"

proc run(arguments: openArray[string]): string =
  var command: seq[string]
  for argument in arguments:
    command.add argument.quoteShell
  let executed = execCmdEx(command.join(" "))
  doAssert executed.exitCode == 0, executed.output
  result = executed.output

proc supportsBif(compiler: string): bool =
  let help = execCmdEx(compiler.quoteShell & " --fullhelp")
  result =
    (defined(macosx) or defined(linux) or defined(freebsd)) and help.exitCode == 0 and
    "--genBif:on|off" in help.output and fileExists(compiler.parentDir / "nifler")

when defined(macosx) or defined(linux) or defined(freebsd):
  let compiler = getCurrentCompilerExe()
  if compiler.supportsBif:
    let
      temporary = createTempDir("binny-native-anonymous-generics-", "")
      source = temporary / "producer.nim"
      cache = temporary / "nimcache"
      backend = cache / "producer-backend"
      dylib =
        when defined(macosx):
          temporary / "libproducer.dylib"
        else:
          temporary / "libproducer.so"
      bindings = temporary / "producer_abi.nim"
    defer:
      removeDir(temporary)

    writeFile(
      source,
      """
type
  Axis = enum
    x, y, z, w

proc sumSequence*(values: seq[int]): int {.noinline.} =
  for value in values:
    result += value

proc sumFixedArray*(values: array[4, int]): int {.noinline.} =
  for value in values:
    result += value

proc sumEnumArray*(values: array[Axis, int]): int {.noinline.} =
  for value in values:
    result += value

proc sumNestedSequence*(values: seq[array[4, int]]): int {.noinline.} =
  for value in values:
    result += value[0]

proc sumNestedArray*(values: array[4, seq[int]]): int {.noinline.} =
  for value in values:
    if value.len > 0:
      result += value[0]
""",
    )
    createDir(cache)

    discard run(
      [
        compiler,
        "ic",
        "--genBif:on",
        "--app:staticlib",
        "--mm:orc",
        "-d:useMalloc",
        "--nimcache:" & cache,
        "--out:" & backend,
        source,
      ]
    )

    let bifPath = findSemanticBifPath(cache, source)
    doAssert "genericargs" in readFile(bifPath)
    let config = initBifNativeBindingsConfig(source, cache, dylib, temporary)
    doAssert config.writeNativeBindings(bindings)
    let generatedBindings = readFile(bindings)
    doAssert "proc sumSequence*(values: seq[int]): int" in generatedBindings
    doAssert "proc sumFixedArray*(values: array[4, int]): int" in generatedBindings
    doAssert "proc sumEnumArray*(values: array[NativeAbi" in generatedBindings
    doAssert "proc sumNestedSequence*(values: seq[array[4, int]]): int" in
      generatedBindings
    doAssert "proc sumNestedArray*(values: array[4, seq[int]]): int" in generatedBindings
    doAssert "    x = 0" in generatedBindings
    doAssert "    y = 1" in generatedBindings
    doAssert "    z = 2" in generatedBindings
    doAssert "    w = 3" in generatedBindings
    doAssert "NativeAbit16_" notin generatedBindings
    doAssert "NativeAbit24_" notin generatedBindings

    let
      consumer = temporary / "consumer.nim"
      consumerCache = cache / "consumer"
      consumerBinary = temporary / "consumer".addFileExt(ExeExt)
    writeFile(consumer, "import producer_abi\n")
    discard run(
      [
        compiler,
        "c",
        "--mm:orc",
        "-d:useMalloc",
        "--nimcache:" & consumerCache,
        "--path:" & temporary,
        "--out:" & consumerBinary,
        consumer,
      ]
    )
  else:
    echo "Skipping anonymous generic BIF test: current Nim lacks --genBif/nifler"
