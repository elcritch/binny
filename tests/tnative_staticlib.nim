import std/[assertions, dynlib, os, osproc, strutils, tempfiles]
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

proc supportsStaticLibExperiment(compiler: string): bool =
  let help = execCmdEx(compiler.quoteShell & " --fullhelp")
  result = (defined(macosx) or defined(linux) or defined(freebsd)) and
    help.exitCode == 0 and
    "--genBif:on|off" in help.output and
    fileExists(compiler.parentDir / "nifler")

proc elfSymbolHasVisibility(output, symbol, visibility: string): bool =
  for line in output.splitLines:
    let fields = line.splitWhitespace
    if fields.len >= 8 and fields[^1] == symbol and visibility in fields:
      return true

proc listsSymbol(output, symbol: string): bool =
  for line in output.splitLines:
    let fields = line.splitWhitespace
    if fields.len > 0 and fields[^1] == symbol:
      return true

when defined(macosx) or defined(linux) or defined(freebsd):
  let compiler = getCurrentCompilerExe()
  if compiler.supportsStaticLibExperiment:
    block public_bif_procs_become_dylib_exports:
      let
        temporary = createTempDir("binny-native-staticlib-", "")
        source = temporary / "producer.nim"
        cache = temporary / "nimcache"
        backend = cache / "producer-backend"
        privateArchive = temporary / "libproducer.private.a"
        publicArchive = temporary / "libproducer.a"
        exportList = temporary / "libproducer.exports"
        dylib = when defined(macosx):
          temporary / "libproducer.dylib"
        else:
          temporary / "libproducer.so"
        bindings = temporary / "producer_abi.nim"
        consumer = temporary / "consumer.nim"
        consumerBinary = temporary / "consumer"
      defer:
        removeDir(temporary)

      writeFile(source, """
type
  Tracked* = object
    value*: int

  `type`* = object
    value*: int

var trackedCopies = 0

proc `=copy`(dest: var Tracked, source: Tracked) =
  inc trackedCopies
  dest.value = source.value

proc publicAdd*(left, right: int): int {.noinline.} =
  left + right

proc publicAnswer*(): int {.noinline.} =
  42

proc sumValues*(values: openArray[int]): int {.noinline.} =
  for value in values:
    result += value

proc newTracked*(value: int): Tracked {.noinline.} =
  Tracked(value: value)

proc trackedCopyCount*(): int {.noinline.} =
  trackedCopies

proc `foo=`*(item: var `type`, value: int) {.noinline.} =
  item.value = value

proc `for`*(item: `type`): int {.noinline.} =
  item.value

proc privateAdd(left, right: int): int {.noinline.} =
  left - right
""")
      createDir(cache)

      let compileArguments = [
        compiler, "ic", "--genBif:on", "--app:staticlib", "--mm:orc",
        "-d:useMalloc", "--nimcache:" & cache, "--out:" & backend, source,
      ]
      discard run(compileArguments)

      let
        exports = rootPublicRoutines(cache, temporary, source)
        bifPath = findSemanticBifPath(cache, source)
        initSymbol = nativeInitSymbol(dylib, bifPath)
      var exportedNames: seq[string]
      for symbol in exports:
        exportedNames.add symbol.nifSymbol
      doAssert exports.len == 8, "unexpected exports: " & exportedNames.join(", ")
      doAssert exports[0].nifSymbol.startsWith("publicAdd.")
      doAssert exports[1].nifSymbol.startsWith("publicAnswer.")
      doAssert exports[0].cSymbol.len > 0
      doAssert exports[1].cSymbol.len > 0
      doAssert initSymbol.startsWith("libproducer_NimMain_")
      writeNativeExportList(exportList, initSymbol, exports)

      discard run(compileArguments)
      when defined(linux) or defined(freebsd):
        compileElfPicObjects(cache, [
          compiler.parentDir.parentDir / "lib", temporary,
        ])

      var archiveArguments = when defined(macosx):
        @["/usr/bin/libtool", "-static", "-o", privateArchive]
      else:
        @["ar", "-rcs", privateArchive]
      for path in walkFiles(cache / "*.o"):
        archiveArguments.add path
      when defined(macosx):
        doAssert archiveArguments.len > 4
      else:
        doAssert archiveArguments.len > 3
      discard run(archiveArguments)

      promoteNativeArchive(privateArchive, publicArchive, exports)
      linkNativeDynlib(publicArchive, dylib, exportList, initSymbol)

      when defined(macosx):
        let
          privateSymbols = run(["/usr/bin/nm", "-m", privateArchive])
          publicSymbols = run(["/usr/bin/nm", "-m", publicArchive])
          dylibSymbols = run(["/usr/bin/nm", "-gU", dylib])
        for symbol in exports:
          doAssert "private external _" & symbol.cSymbol in privateSymbols
          doAssert "external _" & symbol.cSymbol in publicSymbols
          doAssert "_" & symbol.cSymbol in dylibSymbols
        doAssert dylibSymbols.listsSymbol("_" & initSymbol)
        doAssert not dylibSymbols.listsSymbol("_NimMain")
      else:
        let
          privateSymbols = run(["readelf", "-Ws", privateArchive])
          publicSymbols = run(["readelf", "-Ws", publicArchive])
          dylibSymbols = run(["nm", "-D", "--defined-only", dylib])
        for symbol in exports:
          doAssert privateSymbols.elfSymbolHasVisibility(
            symbol.cSymbol, "HIDDEN")
          doAssert publicSymbols.elfSymbolHasVisibility(
            symbol.cSymbol, "DEFAULT")
          doAssert symbol.cSymbol in dylibSymbols
        doAssert dylibSymbols.listsSymbol(initSymbol)
        doAssert not dylibSymbols.listsSymbol("NimMain")
      doAssert "privateAdd" notin dylibSymbols

      let library = loadLib(dylib)
      doAssert not library.isNil
      let initialize = cast[proc() {.cdecl.}](
        library.symAddr(cstring(initSymbol)))
      let publicAdd = cast[proc(left, right: int): int {.nimcall.}](
        library.symAddr(cstring(exports[0].cSymbol)))
      doAssert not initialize.isNil
      doAssert not publicAdd.isNil
      initialize()
      doAssert publicAdd(20, 22) == 42
      library.unloadLib()

      let config = initBifNativeBindingsConfig(
        source, cache, dylib, temporary
      )
      doAssert config.writeNativeBindings(bindings)
      let generatedBindings = readFile(bindings)
      doAssert "importc: \"" & initSymbol & "\"" in generatedBindings
      doAssert "  `type`* = object" in generatedBindings
      doAssert "proc `foo=`*(item: var `type`; value: int)" in generatedBindings
      doAssert "proc `for`*(item: `type`): int" in generatedBindings
      writeFile(consumer, """
import producer_abi

doAssert sumValues([3, 5, 8]) == 16
let original = newTracked(7)
var copied: Tracked
copied = original
doAssert copied.value == 7
doAssert trackedCopyCount() == 1

var quoted = producer_abi.`type`(value: 1)
quoted.foo = 42
doAssert quoted.value == 42
doAssert `for`(quoted) == 42
""")
      discard run([
        compiler, "c", "--mm:orc", "-d:useMalloc",
        "--nimcache:" & (cache / "consumer"), "--out:" & consumerBinary,
        consumer,
      ])
      discard run([consumerBinary])
  else:
    echo "Skipping native static-library test: current Nim lacks --genBif/nifler"
