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
      temporary = createTempDir("binny-native-imported-opaque-", "")
      applicationDirectory = temporary / "application"
      source = applicationDirectory / "producer.nim"
      importedDirectory = temporary / "siwin"
      importedSource = importedDirectory / "window.nim"
      cache = temporary / "nimcache"
      backend = cache / "producer-backend"
      bindings = temporary / "producer_abi.nim"
      consumer = temporary / "consumer.nim"
      consumerCache = cache / "consumer"
      consumerBinary = temporary / ("consumer" & ExeExt)
    defer:
      removeDir(temporary)

    createDir(applicationDirectory)
    createDir(importedDirectory)
    writeFile(
      importedSource,
      """
type
  ClipboardContentChangedEvent* = object
    serial*: int

  Clipboard* = ref object
    onContentChanged*: proc(e: ClipboardContentChangedEvent)

  Window* = ref object
    clipboard*: Clipboard
""",
    )
    writeFile(
      source,
      """
import siwin/window

proc siwinWindowStep*(window: Window): int {.noinline.} =
  if window.isNil:
    0
  else:
    1
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
        "--path:" & temporary,
        "--nimcache:" & cache,
        "--out:" & backend,
        source,
      ]
    )

    let config = initBifNativeBindingsConfig(
      source,
      cache,
      temporary / "libproducer",
      source.parentDir,
      initNativeExportConfig(typeImports = [importType("Window", "siwin/window")]),
    )
    doAssert config.writeNativeBindings(bindings)
    let generated = readFile(bindings)
    doAssert "import siwin/window" in generated
    doAssert "  Window* =" notin generated
    doAssert "Clipboard" notin generated
    doAssert "proc siwinWindowStep*(window: Window): int" in generated
    doAssert "doAssert sizeof(Window) == 8" in generated

    writeFile(
      consumer,
      """
import siwin/window
import producer_abi

static:
  doAssert offsetOf(Window, clipboard) == 0

let instance = Window()
doAssert siwinWindowStep(instance) == 1
""",
    )
    discard run(
      [
        compiler,
        "c",
        "--mm:orc",
        "-d:useMalloc",
        "--path:" & temporary,
        "--nimcache:" & consumerCache,
        "--out:" & consumerBinary,
        consumer,
      ]
    )
  else:
    echo "Skipping imported opaque type test: current Nim lacks --genBif/nifler"
