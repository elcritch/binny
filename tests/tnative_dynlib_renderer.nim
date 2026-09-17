import std/[assertions, json, os, osproc, strutils, tempfiles]
import binny/native_dynlib
import binny/native_dynlib/[bifreader, staticlib]

proc run(arguments: openArray[string]): string =
  var command: seq[string]
  for argument in arguments:
    command.add argument.quoteShell
  let executed = execCmdEx(command.join(" "))
  doAssert executed.exitCode == 0, command.join(" ") & "\n" & executed.output
  executed.output

let compiler = getCurrentCompilerExe()
let help = execCmdEx(compiler.quoteShell & " --fullhelp")
when defined(macosx) or defined(linux) or defined(freebsd) or defined(windows):
  if help.exitCode == 0 and "--genBif:on|off" in help.output and
      fileExists(compiler.parentDir / ("nifler" & ExeExt)):
    const fixture = currentSourcePath.parentDir / "fixtures/native_dynlib_renderer"
    let
      temporary = createTempDir("binny-native-renderer-", "")
      project = temporary / "fixture"
      source = project / "producer.nim"
      cache = temporary / "cache"
      output = cache / "backend"
      library = temporary / DynlibFormat.replace("$1", "renderer")
      exports_file = temporary / "exports"
      public_archive = temporary / "public.a"
      bindings = temporary / "renderer_abi.nim"
    var completed = false
    defer:
      if completed: removeDir(temporary)
      else: echo "Renderer fixture retained at ", temporary
    copyDir(fixture, project)
    createDir(cache)
    var arguments = @[
      compiler, "c", "--genBif:on", "--app:staticlib", "--mm:arc", "-d:useMalloc",
      "--noNimblePath", "--nimcache:" & cache, "--out:" & output,
    ]
    let test_flags =
      when defined(addressSanitizer): @[
        "--passC:-fsanitize=address -fno-omit-frame-pointer", "--passL:-fsanitize=address",
        "-g", "--mangle:nim", "-d:noSignalHandler",
      ]
      elif defined(release): @["-d:release"]
      else: newSeq[string]()
    arguments.add test_flags
    when defined(linux) or defined(freebsd):
      arguments.add "--passC:-fPIC"
    var config = initNativeExportConfig(includeProcs = [
      includeProc("*", "producer.nim"), includeProc("backendKind", "renderer.nim"),
      includeProc("setText*", "renderer.nim"), includeProc("text*", "renderer.nim"),
      includeProc("replaceBackend", "renderer.nim"),
      includeProc("defaultValue", "renderer.nim", typeArgs = @["int"]),
    ])
    for rebuild in 0..1:
      if rebuild == 1:
        config.includeProcs[1].typeArgs = @["backend.nim:BackendState"]
        writeFile(project / "inactive.nim", """
import renderer
proc inactive*(): Renderer[int] =
  result = Renderer[int](state: 3, kind: 11)
  doAssert result.backendKind() == 11
""")
        discard run(arguments & @[project / "inactive.nim"])
        writeFile(cache / "stale.nim.c", "void backendKind_u0__wrong(void) {}")
        copyFile(output & ".json", cache / "stale.json")
      discard run(arguments & @[source])
      var ambiguous_config = config
      ambiguous_config.includeProcs[^1].typeArgs = @[]
      doAssertRaises NativeStaticLibError:
        discard publicRoutineSymbols(cache, project, ambiguous_config, source)
      var missing_config = config
      missing_config.includeProcs[^1].typeArgs = @["uint64"]
      doAssertRaises NativeStaticLibError:
        discard publicRoutineSymbols(cache, project, missing_config, source)
      let root = nativeCRootSourcePath(cache)
      discard prepareNativeRoutines(cache, project, source, root, config,
        cBuildManifest = output & ".json")
      discard run(arguments & @[root])
      let exports = nativeExportSymbols(cache, project, config)
      var kind_count = 0
      for symbol in exports:
        if symbol.nifSymbol.startsWith("backendKind."): inc kind_count
      doAssert kind_count == (if rebuild == 0: 3 else: 2)
      let init_symbol = nativeInitSymbol(library, findSemanticBifPath(cache, source))
      writeNativeExportList(exports_file, init_symbol, exports)
      var archive_arguments =
        when defined(macosx): @["/usr/bin/libtool", "-static", "-o", output & ".a"]
        else: @["ar", "-rcs", output & ".a"]
      for node in parseFile(output & ".json")["link"]:
        archive_arguments.add node.getStr
      discard run(archive_arguments)
      promoteNativeArchive(output & ".a", public_archive, exports)
      let linker_args = when defined(addressSanitizer): @["-fsanitize=address"]
                        else: newSeq[string]()
      linkNativeDynlib(public_archive, library, exports_file, init_symbol, linkerArgs = linker_args)
      discard initBifNativeBindingsConfig(source, cache, library, project, config).
        writeNativeBindings(bindings)
      writeFile(temporary / "consumer.nim", """
import renderer_abi
doAssert defaultValue() == 0
when compiles(backendKind(newOtherRenderer())):
  doAssert backendKind(newOtherRenderer()) == 8
doAssert newOtherRenderer().state.value == 12
proc exerciseRenderer() =
  doAssert releasedCount() == 0
  block:
    let renderer = newRenderer()
    let alias = renderer
    doAssert alias == renderer
    doAssert releasedCount() == 0
  doAssert releasedCount() == 1
exerciseRenderer()
let renderer = newRenderer()
doAssert renderer.state.label == "native!"
doAssert renderer.state.handle.layer == nil
doAssert renderer.backendKind() == 5
doAssert renderer.backendKind(3) == 8
renderer.setTextLcdFiltering(false)
renderer.setTextSubpixelPositioning(false)
renderer.setTextSubpixelGlyphVariants(false)
renderer.replaceBackend(7)
doAssert renderer.backendKind() == 7
doAssert not renderer.textLcdFiltering()
doAssert not renderer.textSubpixelPositioning()
doAssert not renderer.textSubpixelGlyphVariants()
renderer.setTextLcdFiltering(true)
renderer.setTextSubpixelPositioning(true)
renderer.setTextSubpixelGlyphVariants(true)
renderer.replaceBackend(9)
doAssert renderer.textLcdFiltering()
doAssert renderer.textSubpixelPositioning()
doAssert renderer.textSubpixelGlyphVariants()
renderer.contextActivation(renderer)
doAssert renderer.backendKind() == 10
""")
      discard run(@[compiler, "c", "-r", "--mm:arc", "-d:useMalloc", "--noNimblePath",
        "--path:" & temporary, "--nimcache:" & temporary / "consumer-cache",
        "--out:" & temporary / "consumer"] & test_flags & @[temporary / "consumer.nim"])
      let manifest = readFile(temporary / "consumer-cache/consumer.json")
      for module in ["producer.nim", "renderer.nim", "backend.nim", "handles.nim"]:
        doAssert module notin manifest
      var imported_config = config
      imported_config.typeImports = @[importType("LayerHandle", "handles")]
      doAssertRaises NativeBifError:
        discard initBifNativeBindingsConfig(source, cache, library, project, imported_config).
          generateNativeBindings()
      imported_config.typeImports = @[
        importType("LayerHandle", "handles", source = "handles.nim"),
        importType("LayerHandle", "other/handles", exported = false, source = "other/handles.nim"),
      ]
      discard initBifNativeBindingsConfig(source, cache, library, project, imported_config).
        writeNativeBindings(bindings)
      let imported = readFile(bindings)
      doAssert "handles as binnyImport" in imported
      doAssert "export binnyImport" in imported
      writeFile(temporary / "imported_consumer.nim", """
import renderer_abi
import handles
import other/handles as other_handles
let renderer = newRenderer()
let handle: handles.LayerHandle = renderer.state.handle
let other: other_handles.LayerHandle = renderer.state.other
doAssert handle.layer == nil and other.context == nil
static:
  doAssert not compiles(block:
    let wrong: handles.LayerHandle = renderer.state.other)
""")
      discard run(@[compiler, "c", "-r", "--mm:arc", "-d:useMalloc", "--noNimblePath",
        "--path:" & temporary, "--path:" & project,
        "--nimcache:" & temporary / "imported-cache", "--out:" & temporary / "imported_consumer",
      ] & test_flags & @[temporary / "imported_consumer.nim"])
      let imported_manifest = readFile(temporary / "imported-cache/imported_consumer.json")
      for module in ["producer.nim", "renderer.nim", "backend.nim"]:
        doAssert module notin imported_manifest
    completed = true
  else:
    echo "Skipping renderer test: compiler lacks BIF support"
