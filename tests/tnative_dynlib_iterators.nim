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
when defined(macosx) or defined(linux) or defined(freebsd):
  if help.exitCode == 0 and "--genBif:on|off" in help.output and
      fileExists(compiler.parentDir / ("nifler" & ExeExt)):
    for memory_manager in ["arc", "orc"]:
      let
        temporary = createTempDir("binny-native-iterators-", "")
        application = temporary / "application"
        source = application / "producer.nim"
        cache = temporary / "cache"
        backend = cache / "backend"
        public_archive = temporary / "public.a"
        exports_file = temporary / "exports"
        library = temporary / DynlibFormat.replace("$1", "iterators")
        bindings = temporary / "iterators_abi.nim"
        fixture = currentSourcePath.parentDir / "fixtures/native_dynlib_iterators"
      var completed = false
      defer:
        if completed:
          removeDir(temporary)
        else:
          echo "Iterator fixture retained at ", temporary
      createDir(application)
      createDir(cache)
      copyFile(fixture / "producer.nim", source)
      copyFile(fixture / "consumer.nim", temporary / "consumer.nim")
      var flags = @["--mm:" & memory_manager, "-d:useMalloc"]
      when defined(release): flags.add "-d:release"
      when defined(danger): flags.add "-d:danger"
      when defined(addressSanitizer):
        flags.add ["-d:noSignalHandler",
          "--passC:-fsanitize=address -fno-omit-frame-pointer -g",
          "--passL:-fsanitize=address"]
      var arguments = @[compiler, "c", "--genBif:on", "--app:staticlib",
        "--nimcache:" & cache, "--out:" & backend] & flags
      when defined(linux) or defined(freebsd):
        arguments.add "--passC:-fPIC"
      discard run(arguments & @[source])
      let config = initNativeExportConfig(excludeProcs = [excludeProc("excluded")])
      try:
        discard rootPublicRoutines(cache, application, source, config)
        doAssert false, "incremental iterator exports must fail explicitly"
      except NativeStaticLibError as error:
        doAssert "iterator exports currently require the normal C backend" in error.msg
      let root = nativeCRootSourcePath(cache)
      discard prepareNativeRoutines(cache, application, source, root, config,
        cBuildManifest = backend & ".json")
      discard run(arguments & @[root])
      let exports = nativeExportSymbols(cache, application, config)
      var iterators = 0
      for symbol in exports:
        if symbol.iteratorRoutine:
          inc iterators
          doAssert symbol.cSymbol.startsWith("binny_iterator_")
      doAssert iterators == 13
      let init_symbol = nativeInitSymbol(library, findSemanticBifPath(cache, source))
      writeNativeExportList(exports_file, init_symbol, exports)
      var archive_arguments =
        when defined(macosx): @["/usr/bin/libtool", "-static", "-o", backend & ".a"]
        else: @["ar", "-rcs", backend & ".a"]
      for node in parseFile(backend & ".json")["link"]:
        archive_arguments.add node.getStr
      discard run(archive_arguments)
      promoteNativeArchive(backend & ".a", public_archive, exports)
      let linker_args = when defined(addressSanitizer): @["-fsanitize=address"]
                        else: newSeq[string]()
      linkNativeDynlib(public_archive, library, exports_file, init_symbol,
        linkerArgs = linker_args)
      let binding_config = initBifNativeBindingsConfig(source, cache, library, application, config)
      discard binding_config.writeNativeBindings(bindings)
      discard run(@[compiler, "c", "-r", "--noNimblePath", "--path:" & temporary,
        "--nimcache:" & temporary / "consumer-cache", "--out:" & temporary / "consumer"] &
        flags & @[temporary / "consumer.nim"])
      let manifest = readFile(temporary / "consumer-cache/consumer.json")
      doAssert "producer.nim" notin manifest
      completed = true
  else:
    echo "Skipping native iterator test: compiler lacks BIF support"
