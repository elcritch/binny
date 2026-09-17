import std/[assertions, json, os, osproc, strutils, tempfiles]
import binny/native_dynlib
import binny/native_dynlib/staticlib

proc run(arguments: openArray[string]): string =
  var command: seq[string]
  for argument in arguments:
    command.add argument.quoteShell
  let executed = execCmdEx(command.join(" "))
  doAssert executed.exitCode == 0, command.join(" ") & "\n" & executed.output
  result = executed.output

let compiler = getCurrentCompilerExe()
let help = execCmdEx(compiler.quoteShell & " --fullhelp")
when defined(macosx) or defined(linux) or defined(freebsd) or defined(windows):
  if help.exitCode == 0 and "--genBif:on|off" in help.output and
      fileExists(compiler.parentDir / ("nifler" & ExeExt)):
    for backend in ["c", "ic"]:
      let
        temporary = createTempDir("binny-native-methods-", "")
        application = temporary / "application"
        source = application / "producer.nim"
        dependency = temporary / "siwin" / "window.nim"
        cache = temporary / "cache"
        archive = cache / "backend"
        public_archive = temporary / "public.a"
        exports_file = temporary / "exports"
        library = temporary / DynlibFormat.replace("$1", "methods")
        bindings = temporary / "methods_abi.nim"
        consumer = temporary / "consumer.nim"
        consumer_binary = temporary / ("consumer" & ExeExt)
      var completed = false
      defer:
        if completed:
          removeDir(temporary)
        else:
          echo "Native method fixture retained at ", temporary
      createDir(application)
      createDir(dependency.parentDir)
      createDir(cache)
      writeFile(dependency, """
import std/[options, tables, times]
type
  MouseButton* = enum
    left, right
  Touch* = ref object
    button*: Option[MouseButton]
  Point* = object
    x*, y*: int
  CursorKind* = enum
    ckBuiltin, ckImage
  Cursor* = object
    case kind*: CursorKind
    of ckBuiltin: builtin*: uint8
    else: image*: Point
  Window* = ref object of RootObj
    value*: int
    touches*: Table[int, Touch]
    button*: Option[MouseButton]
    region*: Option[tuple[x, y: int]]
    duration*: Duration
    onValue*: proc(value: int)
    cursor*: Cursor

method currentValue*(window: Window): int {.base.} = -1
method `currentValue=`*(window: Window, value: int) {.base.} =
  window.value = -999
method location*(window: Window): Point {.base.} = Point(x: -1, y: -1)
method `location=`*(window: Window, point: Point) {.base.} = window.value = -999
proc notify*(window: Window) =
  window.onValue(window.currentValue())
proc touchButton*(window: Window, index: int): MouseButton =
  window.touches[index].button.get()
proc regionValue*(window: Window): int =
  window.region.get().x
proc cursorValue*(window: Window): int =
  window.cursor.image.x + window.cursor.image.y
""")
      writeFile(source, """
import siwin/window
type DerivedWindow* = ref object of Window
method currentValue*(window: DerivedWindow): int = window.value + 2
method `currentValue=`*(window: DerivedWindow, value: int) = window.value = value + 3
method location*(window: DerivedWindow): Point =
  Point(x: window.value, y: window.value + 1)
method `location=`*(window: DerivedWindow, point: Point) =
  window.value = point.x + point.y
proc newWindow*(): Window = DerivedWindow(value: 40)
""")
      var arguments = @[
        compiler, backend, "--genBif:on", "--app:staticlib", "--mm:arc",
        "-d:useMalloc", "--path:" & temporary, "--nimcache:" & cache,
        "--out:" & archive,
      ]
      when defined(linux) or defined(freebsd):
        if backend == "c":
          arguments.add "--passC:-fPIC"
      discard run(arguments & @[source])
      let export_config = initNativeExportConfig(
        includeProcs = [
          includeProc("*", "producer.nim"),
          includeProc("*", "../siwin/window.nim"),
        ],
        typeImports = [importType("Duration", "std/times")],
      )
      let root_source = nativeCRootSourcePath(cache)
      discard prepareNativeRoutines(cache, application, source, root_source, export_config)
      discard run(arguments & @[(if backend == "c": root_source else: source)])
      let exports = nativeExportSymbols(cache, application, export_config)
      var methods = 0
      var dispatchers: seq[string]
      for symbol in exports:
        if symbol.backendNifSymbol.len > 0:
          inc methods
          doAssert symbol.backendNifSymbol != symbol.nifSymbol
          doAssert symbol.cSymbol.len > 0
          if symbol.cSymbol notin dispatchers:
            dispatchers.add symbol.cSymbol
      doAssert methods == 8
      doAssert dispatchers.len == 4
      let init_symbol = nativeInitSymbol(library, findSemanticBifPath(cache, source))
      writeNativeExportList(exports_file, init_symbol, exports)
      when defined(linux) or defined(freebsd):
        if backend == "ic":
          compileElfPicObjects(cache)
      var archive_arguments =
        when defined(macosx): @["/usr/bin/libtool", "-static", "-o", archive & ".a"]
        else: @["ar", "-rcs", archive & ".a"]
      if backend == "c":
        for node in parseJson(readFile(archive & ".json"))["link"]:
          archive_arguments.add node.getStr
      else:
        for path in walkFiles(cache / "*.o"):
          archive_arguments.add path
      discard run(archive_arguments)
      promoteNativeArchive(archive & ".a", public_archive, exports)
      linkNativeDynlib(public_archive, library, exports_file, init_symbol)
      let config = initBifNativeBindingsConfig(source, cache, library, application, export_config)
      doAssert config.writeNativeBindings(bindings)
      let generated = readFile(bindings)
      doAssert "siwin/window" notin generated
      doAssert "std/options" in generated
      doAssert "std/tables" in generated
      doAssert "RootObj* {.inheritable.} = object\n" in generated
      doAssert "Table[int, Touch]" in generated
      doAssert "Option[MouseButton]" in generated
      writeFile(consumer, """
import methods_abi
import std/[options, tables]
let window = newWindow()
doAssert window.currentValue() == 42
doAssert window.location() == Point(x: 40, y: 41)
window.location = Point(x: 20, y: 30)
doAssert window.currentValue() == 52
window.currentValue = 90
doAssert window.currentValue() == 95
window.button = some(MouseButton.right)
doAssert window.button.get() == MouseButton.right
window.touches[4] = Touch(button: some(MouseButton.left))
doAssert window.touchButton(4) == MouseButton.left
window.region = some((x: 7, y: 8))
doAssert window.regionValue() == 7
window.cursor = Cursor(kind: ckImage, image: Point(x: 7, y: 8))
doAssert window.cursorValue() == 15
var observed = 0
window.onValue = proc(value: int) = observed = value
window.notify()
doAssert observed == 95
""")
      discard run([
        compiler, "c", "-r", "--mm:arc", "-d:useMalloc", "--path:" & temporary,
        "--nimcache:" & temporary / "consumer-cache", "--out:" & consumer_binary,
        consumer,
      ])
      doAssert "siwin/window.nim" notin readFile(
        temporary / "consumer-cache" / "consumer.json"
      ).replace('\\', '/')
      completed = true
  else:
    echo "Skipping native method test: compiler lacks BIF support"
