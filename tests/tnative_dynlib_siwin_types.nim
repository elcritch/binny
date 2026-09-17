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
  const
    project_root = currentSourcePath.parentDir.parentDir
    fixture = currentSourcePath.parentDir / "fixtures/native_dynlib_siwin_types"
    vmath_source = project_root / "deps/vmath/src"
  if help.exitCode == 0 and "--genBif:on|off" in help.output and
      fileExists(compiler.parentDir / ("nifler" & ExeExt)) and
      fileExists(vmath_source / "vmath.nim"):
    for backend in ["c", "ic"]:
      for memory_manager in ["arc", "orc"]:
        let
          temporary = createTempDir("binny-native-siwin-types-", "")
          project = temporary / "fixture"
          application = project / "app"
          source = application / "producer.nim"
          cache = temporary / "cache"
          output = cache / "backend"
          public_archive = temporary / "public.a"
          library = temporary / DynlibFormat.replace("$1", "siwin_types")
          exports_file = temporary / "exports"
          bindings = temporary / "siwin_abi.nim"
          consumer = temporary / "consumer.nim"
        var completed = false
        defer:
          if completed:
            removeDir(temporary)
          else:
            echo "Siwin types fixture retained at ", temporary
        copyDir(fixture, project)
        createDir(cache)
        var arguments = @[
          compiler, backend, "--genBif:on", "--app:staticlib", "--mm:" & memory_manager,
          "-d:useMalloc", "--noNimblePath", "--path:" & vmath_source,
          "--nimcache:" & cache, "--out:" & output,
        ]
        when defined(linux) or defined(freebsd):
          if backend == "c":
            arguments.add "--passC:-fPIC"
        discard run(arguments & @[source])
        let config = initNativeExportConfig(
          includeProcs = [
            includeProc("*", "producer.nim"),
            includeProc("startInteractive*", "../siwin/window.nim"),
            includeProc("showWindowMenu", "../siwin/window.nim"),
            includeProc("icon=", "../siwin/window.nim"),
            includeProc("widePosition", "../siwin/window.nim"),
            includeProc("localPosition", "../siwin/window.nim"),
          ],
          typeImports = [importType("Vec2", "vmath"), importType("DVec2", "vmath")],
        )
        let root = nativeCRootSourcePath(cache)
        let manifest = if backend == "c": output & ".json" else: ""
        discard prepareNativeRoutines(cache, application, source, root, config,
          cBuildManifest = manifest)
        discard run(arguments & @[(if backend == "c": root else: source)])
        let exports = nativeExportSymbols(cache, application, config)
        let init_symbol = nativeInitSymbol(library, findSemanticBifPath(cache, source))
        writeNativeExportList(exports_file, init_symbol, exports)
        when defined(linux) or defined(freebsd):
          if backend == "ic":
            compileElfPicObjects(cache)
        var archive_arguments =
          when defined(macosx): @["/usr/bin/libtool", "-static", "-o", output & ".a"]
          else: @["ar", "-rcs", output & ".a"]
        if backend == "c":
          for node in parseFile(output & ".json")["link"]:
            archive_arguments.add node.getStr
        else:
          for object_path in walkFiles(cache / "*.o"):
            archive_arguments.add object_path
        discard run(archive_arguments)
        promoteNativeArchive(output & ".a", public_archive, exports)
        linkNativeDynlib(public_archive, library, exports_file, init_symbol)
        discard initBifNativeBindingsConfig(source, cache, library, application, config).
          writeNativeBindings(bindings)
        let generated = readFile(bindings)
        doAssert "Option[Vec2]" in generated
        doAssert "Option[NativeAbi" notin generated
        doAssert "doAssert sizeof(Option[Vec2]) == 12" in generated
        doAssert "doAssert alignof(Option[Vec2]) == 4" in generated
        doAssert "Option[DVec2]" in generated
        doAssert "doAssert sizeof(Option[DVec2]) == 24" in generated
        doAssert "Option[LocalVec2]" in generated
        doAssert "value: typeof(nil)" in generated
        doAssert "value: PixelBuffer" in generated
        doAssert "siwin/window" notin generated
        writeFile(consumer, """
import siwin_abi
import std/options
import vmath

let window = newWindow()
let position: Option[vmath.Vec2] = some(vec2(3, 5))
window.startInteractiveMove(position)
doAssert window.value == 8
window.startInteractiveMove(none(vmath.Vec2))
doAssert window.value == -1
window.startInteractiveResize(right, position)
doAssert window.value == 4
window.startInteractiveResize(left, none(vmath.Vec2))
doAssert window.value == -2
window.showWindowMenu(position)
doAssert window.value == 5
window.showWindowMenu(none(vmath.Vec2))
doAssert window.value == -3
window.icon = nil
doAssert window.value == -4
window.icon = PixelBuffer(width: 2, height: 3, data: @[7'u8])
doAssert window.value == 12
doAssert widePosition(some(dvec2(2, 6))) == 8
doAssert widePosition(none(vmath.DVec2)) == -5
doAssert localPosition(some(LocalVec2(x: 2, y: 7))) == 9
doAssert localPosition(none(LocalVec2)) == -6
static:
  doAssert not compiles(block:
    window.icon = cast[pointer](nil))
  doAssert not compiles(block:
    discard widePosition(some(vec2(2, 6))))
  doAssert not compiles(block:
    discard localPosition(some(vec2(2, 7))))
""")
        discard run(@[
          compiler, "c", "-r", "--mm:" & memory_manager, "-d:useMalloc", "--noNimblePath",
          "--path:" & temporary, "--path:" & vmath_source,
          "--nimcache:" & temporary / "consumer-cache", "--out:" & temporary / "consumer",
          consumer,
        ])
        let consumer_manifest = readFile(temporary / "consumer-cache/consumer.json")
        for module in ["producer.nim", "window.nim"]:
          doAssert module notin consumer_manifest
        completed = true
  else:
    echo "Skipping Siwin types test: compiler lacks BIF or run atlas install --feature:test"
