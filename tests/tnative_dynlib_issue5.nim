import std/[assertions, os, osproc, strutils, tempfiles]
import binny/native_dynlib

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
    (defined(macosx) or defined(linux) or defined(freebsd) or defined(windows)) and
    help.exitCode == 0 and "--genBif:on|off" in help.output and
    fileExists(compiler.parentDir / ("nifler" & ExeExt))

when defined(macosx) or defined(linux) or defined(freebsd) or defined(windows):
  let compiler = getCurrentCompilerExe()
  if compiler.supportsBif:
    let
      temporary = createTempDir("binny-native-issue5-", "")
      source = temporary / "producer.nim"
      cache = temporary / "nimcache"
      backend = cache / "producer-backend"
      bindings = temporary / "producer_abi.nim"
      consumer = temporary / "consumer.nim"
      consumerCache = cache / "consumer"
      consumerBinary = temporary / ("consumer" & ExeExt)
    defer:
      removeDir(temporary)

    writeFile(
      source,
      """
import std/unicode

type
  Utf8Runes* = ref object
    text: string

proc initUtf8Runes*(text: sink string): Utf8Runes {.noinline.} =
  new result
  result.text = text

proc initUtf8Runes*(runes: openArray[Rune]): Utf8Runes {.noinline.} =
  new result
  result.text = $runes.len
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

    let config = initBifNativeBindingsConfig(source, cache, temporary / "libproducer")
    doAssert config.writeNativeBindings(bindings)
    let generated = readFile(bindings)
    doAssert generated.count("proc initUtf8Runes*") == 2
    doAssert "proc initUtf8Runes*(text: string): Utf8Runes" in generated
    doAssert "proc initUtf8Runes*(runes: openArray[Rune]): Utf8Runes" in generated

    writeFile(
      consumer,
      """
import producer_abi

let fromText = initUtf8Runes("hello")
let fromRunes = initUtf8Runes(@[producer_abi.Rune(65)])
doAssert fromText != nil
doAssert fromRunes != nil
""",
    )
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
    echo "Skipping native dynlib issue #5 test: current Nim lacks --genBif/nifler"
