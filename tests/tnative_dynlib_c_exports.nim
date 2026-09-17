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
    const fixture = currentSourcePath.parentDir / "fixtures/native_dynlib_c_exports"
    let
      temporary = createTempDir("binny-native-c-exports-", "")
      project = temporary / "fixture"
      application = project / "app"
      source = application / "producer.nim"
      cache = project / "build/cache"
      backend = cache / "backend"
      publicArchive = temporary / "public.a"
      library = temporary / DynlibFormat.replace("$1", "direct")
      exportsFile = temporary / "exports"
      bindings = temporary / "direct_abi.nim"
      consumer = temporary / "consumer.nim"
    var completed = false
    defer:
      if completed:
        removeDir(temporary)
      else:
        echo "C exports fixture retained at ", temporary
    createDir(cache)
    copyDir(fixture, project)
    let testFlags =
      when defined(addressSanitizer): @[
        "--passC:-fsanitize=address -fno-omit-frame-pointer", "--passL:-fsanitize=address",
        "-g", "--mangle:nim", "-d:noSignalHandler",
      ]
      elif defined(release): @["-d:release"]
      else: newSeq[string]()
    var arguments = @[
      compiler, "c", "--genBif:on", "--app:staticlib", "--mm:arc", "-d:useMalloc",
      "--nimcache:" & cache, "--out:" & backend,
    ]
    arguments.add testFlags
    when defined(linux) or defined(freebsd):
      arguments.add "--passC:-fPIC"
    var config = initNativeExportConfig(includeProcs = [
      includeProc("*", "producer.nim"),
      includeProc("newImage", "../dep/common.nim"),
      includeProc("copy", "../dep/common.nim"),
      includeProc("*", "../dep/pixie.nim"),
      includeProc("*", "../other/common.nim"),
      includeProc("runeLenAt", "*lib/pure/unicode.nim"),
    ])
    var firstSources: seq[string]
    for rebuild in 0..1:
      if rebuild == 1:
        config.excludeProcs = @[excludeProc("*", "producer.nim")]
        # Inactive definitions and an old build description must not influence resolution.
        writeFile(cache / "stale.nim.c", """
void newImage_u0__OOZOOZOOZdepZcommon(void) {}
void copy_u0__OOZOOZOOZdepZcommon(void) {}
void copy_u1__OOZOOZOOZdepZcommon(void) {}
""")
        copyFile(backend & ".json", cache / "stale.json")
        writeFile(cache / "stale.c.nif", "not an active incremental artifact")
      discard run(arguments & @[source])
      if rebuild == 0:
        for node in parseFile(backend & ".json")["link"]:
          firstSources.add node.getStr
      let root = nativeCRootSourcePath(cache)
      doAssert prepareNativeRoutines(cache, application, source, root, config,
        cBuildManifest = backend & ".json") == ncbC
      discard run(arguments & @[root])
      var activeObjects: seq[string]
      for node in parseFile(backend & ".json")["link"]:
        activeObjects.add node.getStr
      if rebuild == 0:
        var inactive = 0
        for objectPath in firstSources:
          let extension = objectPath.splitFile.ext
          if objectPath notin activeObjects and extension in [".o", ".obj"]:
            inc inactive
            doAssert fileExists(objectPath[0 ..< objectPath.len - extension.len])
        doAssert inactive > 0, "fixture must retain C artifacts from the first pass"
      let exports = nativeExportSymbols(cache, application, config)
      for symbol in exports:
        if symbol.nifSymbol.startsWith("readImage."):
          doAssert symbol.cSymbol.startsWith("binny_inline_")
      let initSymbol = nativeInitSymbol(library, findSemanticBifPath(cache, source))
      writeNativeExportList(exportsFile, initSymbol, exports)
      var archiveArguments =
        when defined(macosx): @["/usr/bin/libtool", "-static", "-o", backend & ".a"]
        else: @["ar", "-rcs", backend & ".a"]
      for node in parseJson(readFile(backend & ".json"))["link"]:
        archiveArguments.add node.getStr
      discard run(archiveArguments)
      promoteNativeArchive(backend & ".a", publicArchive, exports)
      let linkerArgs = when defined(addressSanitizer): @["-fsanitize=address"]
                       else: newSeq[string]()
      linkNativeDynlib(publicArchive, library, exportsFile, initSymbol, linkerArgs = linkerArgs)
      let bindingConfig = initBifNativeBindingsConfig(source, cache, library, application, config)
      discard bindingConfig.writeNativeBindings(bindings)
      writeFile(consumer, """
import direct_abi
let image: Image = newImage(4, 5)
image.data[0] = 9
let duplicate = copy(image)
doAssert duplicate != image
doAssert duplicate.width == 4 and duplicate.data[0] == 9
doAssert copy(image, 2).width == 6
let other = newImage(4'u16, 5'u16)
doAssert other == 9 and copy(1) == 101
doAssert producerInitialized()
when declared(producerValue):
  doAssert producerValue() == 112
let loaded = readImage("direct")
doAssert loaded.width == 6 and loaded.height == 2
doAssert readImage(5).height == 3
doAssert readImage(1'u16) == 201
doAssert runeLenAt("a", 0) == 1
doAssert inheritedInline(12) == 13
doAssert sumValues([1, 2, 3]) == 6
doAssert consumeStrings(@["a", "b"]) == 2
doAssert borrowWidth(image) == 4
mutableWidth(image) = 7
doAssert borrowWidth(image) == 7
when declared(consumeOwned):
  proc testInlineSink() =
    doAssert releasedCount() == 0
    var owned = newOwned(41)
    doAssert consumeOwned(ensureMove(owned)) == 41
    doAssert releasedCount() == 1
    doAssert consumeOwned(newOwned(42)) == 42
    doAssert releasedCount() == 2
  testInlineSink()
""")
      discard run(@[
        compiler, "c", "-r", "--mm:arc", "-d:useMalloc", "--path:" & temporary,
        "--nimcache:" & temporary / "consumer-cache", "--out:" & temporary / "consumer",
      ] & testFlags & @[consumer])
      let manifest = readFile(temporary / "consumer-cache" / "consumer.json").replace('\\', '/')
      # Compiler cache paths encode separators, but retain these source basenames.
      for module in ["producer.nim", "common.nim", "pixie.nim"]:
        doAssert module notin manifest
    completed = true
  else:
    echo "Skipping C exports test: compiler lacks BIF support"
