import std/[algorithm, json, os, strutils]

func parentDir(path: string): string =
  for index in countdown(path.high, 0):
    if path[index] == '/':
      return path[0 ..< index]

func path(parent, child: string): string =
  parent & "/" & child

func quoteShell(value: string): string =
  result = "'"
  for ch in value:
    if ch == '\'':
      result.add "'\"'\"'"
    else:
      result.add ch
  result.add "'"

func quoteShellCommand(args: openArray[string]): string =
  for index, arg in args:
    if index > 0:
      result.add ' '
    result.add quoteShell(arg)

let
  exampleDir = parentDir(currentSourcePath)
  projectDir = parentDir(parentDir(exampleDir))
  compiler = selfExe()
  nimcacheDir = path(exampleDir, "nimcache")
  producerBackend = getEnv("BINNY_NATIVE_BACKEND", "c").toLowerAscii()
  backendDir = path(nimcacheDir, producerBackend)
  producerCache = path(backendDir, "producer")
  toolCache = path(backendDir, "tool")
  generatorCache = path(backendDir, "generator")
  consumerCache = path(backendDir, "consumer")
  generatedDir = path(exampleDir, "generated")
  producerSource = path(exampleDir, "producer.nim")
  consumerSource = path(exampleDir, "consumer.nim")
  generatorSource = path(exampleDir, "generate.nim")
  toolSource = path(projectDir, "tools/native_dynlib.nim")
  toolBinary = path(toolCache, "native_dynlib")
  cRootSource = path(producerCache, "binny_native_root.nim")
  generatorBinary = path(generatorCache, "generate")
  consumerBinary = path(exampleDir, "consumer")
  bindings = path(generatedDir, "producer_abi.nim")
  backendOutput = path(producerCache, "producer-backend")
  privateArchive = path(backendDir, "libproducer.private.a")
  publicArchive = path(backendDir, "libproducer.a")
  exportList = path(backendDir, "libproducer.exports")
  exportConfig = path(exampleDir, "native_dynlib.json")
  library =
    case hostOS
    of "macosx":
      path(backendDir, "libproducer.dylib")
    of "linux", "freebsd":
      path(backendDir, "libproducer.so")
    else:
      raise newException(
        ValueError,
        "native dynamic libraries currently support macOS, Linux, and FreeBSD",
      )

proc runNim(args: openArray[string]) =
  var command = @[compiler]
  for arg in args:
    command.add arg
  exec quoteShellCommand(command)

proc runCommand(args: openArray[string]) =
  exec quoteShellCommand(args)

proc producerArtifactsExist() =
  if not fileExists(library) or not fileExists(publicArchive) or
      not fileExists(exportList):
    raise
      newException(IOError, "producer artifacts are missing; run `nim producer` first")

proc compileProducerBackend(source: string, force = false) =
  if producerBackend notin ["c", "ic"]:
    raise newException(ValueError, "BINNY_NATIVE_BACKEND must be either 'c' or 'ic'")
  var arguments =
    @[
      producerBackend,
      "--genBif:on",
      "--app:staticlib",
      "--mm:orc",
      "-d:useMalloc",
      "--nimcache:" & producerCache,
      "--out:" & backendOutput,
    ]
  if force:
    arguments.add "-f"
  if producerBackend == "c" and (hostOS == "linux" or hostOS == "freebsd"):
    arguments.add "--passC:-fPIC"
  arguments.add source
  runNim(arguments)

proc buildNativeDynlibTool() =
  runNim(
    [
      "c",
      "-d:release",
      "--hints:off",
      "--path:" & projectDir,
      "--nimcache:" & toolCache,
      "--out:" & toolBinary,
      toolSource,
    ]
  )

proc archiveProducerObjects() =
  var objects: seq[string]
  if producerBackend == "c":
    let buildDescription = parseJson(readFile(backendOutput & ".json"))
    for objectNode in buildDescription["link"]:
      let objectPath = objectNode.getStr()
      if objectPath.endsWith(".o") and objectPath notin objects:
        objects.add objectPath
  else:
    for objectPath in listFiles(producerCache):
      if objectPath.endsWith(".o"):
        objects.add objectPath
  objects.sort()
  if objects.len == 0:
    raise newException(IOError, "producer backend emitted no object files")
  var command =
    case hostOS
    of "macosx":
      @["/usr/bin/libtool", "-static", "-o", privateArchive]
    of "linux", "freebsd":
      @["ar", "-rcs", privateArchive]
    else:
      raise newException(
        ValueError,
        "native dynamic libraries currently support macOS, Linux, and FreeBSD",
      )
  command.add objects
  runCommand(command)

proc expectedExportNames(): seq[string] =
  var inGlobalSection = false
  for line in readFile(exportList).splitLines:
    let value = line.strip
    case hostOS
    of "macosx":
      if value.len > 0:
        result.add value
    of "linux", "freebsd":
      if value == "global:":
        inGlobalSection = true
      elif value == "local:":
        inGlobalSection = false
      elif inGlobalSection and value.endsWith(";"):
        let name = value[0 ..< value.high].strip
        if name.len > 0:
          result.add name

proc verifyExports() =
  let
    command =
      case hostOS
      of "macosx":
        @["/usr/bin/nm", "-gU", library]
      of "linux", "freebsd":
        @["nm", "-D", "--defined-only", library]
      else:
        raise newException(
          ValueError,
          "native dynamic libraries currently support macOS, Linux, and FreeBSD",
        )
    (output, exitCode) = gorgeEx(quoteShellCommand(command))
    expected = expectedExportNames()
  if exitCode != 0:
    raise
      newException(OSError, "nm failed for the generated dynamic library:\n" & output)
  var actual: seq[string]
  for line in output.splitLines:
    let fields = line.splitWhitespace
    if fields.len > 0:
      actual.add fields[^1]
  actual.sort()
  var sortedExpected = expected
  sortedExpected.sort()
  if actual != sortedExpected:
    raise newException(
      OSError, "dynamic library exports do not match the BIF-derived export list"
    )

proc verifyDeadCodeElimination() =
  let
    command =
      case hostOS
      of "macosx":
        @["/usr/bin/nm", privateArchive]
      of "linux", "freebsd":
        @["nm", privateArchive]
      else:
        raise newException(
          ValueError,
          "native dynamic libraries currently support macOS, Linux, and FreeBSD",
        )
    (output, exitCode) = gorgeEx(quoteShellCommand(command))
  if exitCode != 0:
    raise newException(OSError, "nm failed for the private archive:\n" & output)
  for name in ["ignoredDebugMessage", "ignoredMetric"]:
    if name in output:
      raise newException(
        OSError, "excluded procedure survived dead-code elimination: " & name
      )

proc buildProducer() =
  buildNativeDynlibTool()
  compileProducerBackend(producerSource)
  runCommand(
    [
      toolBinary,
      "prepare",
      producerCache,
      exampleDir,
      producerSource,
      cRootSource,
      "--config:" & exportConfig,
    ]
  )
  if producerBackend == "c":
    compileProducerBackend(cRootSource, force = true)
  else:
    compileProducerBackend(producerSource)
  runCommand(
    [
      toolBinary,
      "exports",
      producerCache,
      exampleDir,
      producerSource,
      library,
      exportList,
      "--config:" & exportConfig,
    ]
  )
  if producerBackend == "ic" and (hostOS == "linux" or hostOS == "freebsd"):
    runCommand([toolBinary, "pic", producerCache])
  archiveProducerObjects()
  verifyDeadCodeElimination()
  runCommand([toolBinary, "promote", privateArchive, publicArchive, exportList])
  runCommand([toolBinary, "link", publicArchive, library, exportList])
  verifyExports()
  producerArtifactsExist()

proc generateBindings() =
  producerArtifactsExist()
  runNim(
    [
      "c",
      "-d:release",
      "--hints:off",
      "--path:" & projectDir,
      "--nimcache:" & generatorCache,
      "--out:" & generatorBinary,
      generatorSource,
    ]
  )
  runCommand(
    [
      generatorBinary, producerCache, exampleDir, producerSource, bindings, library,
      exportConfig,
    ]
  )
  let generatedBindings = readFile(bindings)
  if "proc ignoredDebugMessage*" in generatedBindings or
      "proc ignoredMetric*" in generatedBindings:
    raise newException(
      OSError, "excluded public procedures were emitted in generated bindings"
    )

proc buildConsumer() =
  if not fileExists(bindings):
    raise
      newException(IOError, "generated bindings are missing; run `nim bindings` first")
  runNim(
    [
      "c",
      "--mm:orc",
      "-d:useMalloc",
      "--nimcache:" & consumerCache,
      "--out:" & consumerBinary,
      consumerSource,
    ]
  )

proc runConsumer() =
  runCommand([consumerBinary])

proc checkMoveOnlyBinding() =
  let command = quoteShellCommand(
    [
      compiler,
      "c",
      "--hints:off",
      "--warnings:off",
      "--mm:orc",
      "-d:useMalloc",
      "--nimcache:" & consumerCache,
      "--out:" & path(consumerCache, "consumer_copy_should_fail"),
      path(exampleDir, "consumer_copy_should_fail.nim"),
    ]
  )
  let (_, exitCode) = gorgeEx(command)
  if exitCode == 0:
    raise newException(
      OSError, "copying a generated move-only binding unexpectedly compiled"
    )

task producer, "Build a native-ABI dylib from ordinary public Nim procs":
  buildProducer()

task bindings, "Generate consumer bindings from BIF and compiler C artifacts":
  buildProducer()
  generateBindings()

task consumer, "Build the library and run its generated Nim consumer":
  buildProducer()
  generateBindings()
  buildConsumer()
  runConsumer()

task build, "Build the promoted library and generated consumer":
  buildProducer()
  generateBindings()
  buildConsumer()

task nativeDynlibTest, "Build and run the BIF-derived native dynlib example":
  buildTask()
  runConsumer()
  checkMoveOnlyBinding()

task e2e, "Alias for the native dynamic-library test":
  nativeDynlibTestTask()
