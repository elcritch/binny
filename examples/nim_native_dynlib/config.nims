import std/[algorithm, os, strutils]

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
  nimLibDir = path(parentDir(parentDir(compiler)), "lib")
  nimcacheDir = path(exampleDir, "nimcache")
  producerCache = path(nimcacheDir, "producer")
  toolCache = path(nimcacheDir, "tool")
  generatorCache = path(nimcacheDir, "generator")
  consumerCache = path(nimcacheDir, "consumer")
  generatedDir = path(exampleDir, "generated")
  producerSource = path(exampleDir, "producer.nim")
  consumerSource = path(exampleDir, "consumer.nim")
  generatorSource = path(exampleDir, "generate.nim")
  toolSource = path(projectDir, "tools/native_dynlib.nim")
  toolBinary = path(toolCache, "native_dynlib")
  generatorBinary = path(generatorCache, "generate")
  consumerBinary = path(exampleDir, "consumer")
  bindings = path(generatedDir, "producer_abi.nim")
  backendOutput = path(producerCache, "producer-backend")
  privateArchive = path(nimcacheDir, "libproducer.private.a")
  publicArchive = path(nimcacheDir, "libproducer.a")
  exportList = path(nimcacheDir, "libproducer.exports")
  library = case hostOS
    of "macosx": path(nimcacheDir, "libproducer.dylib")
    of "linux": path(nimcacheDir, "libproducer.so")
    else: raise newException(ValueError,
      "native dynamic libraries currently support macOS and Linux")

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
    raise newException(IOError,
      "producer artifacts are missing; run `nim producer` first")

proc compileProducerBackend() =
  runNim([
    "ic", "--genBif:on", "--app:staticlib", "--mm:orc", "-d:useMalloc",
    "--nimcache:" & producerCache, "--out:" & backendOutput,
    producerSource
  ])

proc buildNativeDynlibTool() =
  runNim([
    "c", "-d:release", "--hints:off", "--path:" & projectDir,
    "--nimcache:" & toolCache, "--out:" & toolBinary, toolSource
  ])

proc archiveProducerObjects() =
  var objects: seq[string]
  for objectPath in listFiles(producerCache):
    if objectPath.endsWith(".o"):
      objects.add objectPath
  objects.sort()
  if objects.len == 0:
    raise newException(IOError, "producer backend emitted no object files")
  var command = case hostOS
    of "macosx": @["/usr/bin/libtool", "-static", "-o", privateArchive]
    of "linux": @["ar", "-rcs", privateArchive]
    else: raise newException(ValueError,
      "native dynamic libraries currently support macOS and Linux")
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
    of "linux":
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
    command = case hostOS
      of "macosx": @["/usr/bin/nm", "-gU", library]
      of "linux": @["nm", "-D", "--defined-only", library]
      else: raise newException(ValueError,
        "native dynamic libraries currently support macOS and Linux")
    (output, exitCode) = gorgeEx(quoteShellCommand(command))
    expected = expectedExportNames()
  if exitCode != 0:
    raise newException(OSError,
      "nm failed for the generated dynamic library:\n" & output)
  var actual: seq[string]
  for line in output.splitLines:
    let fields = line.splitWhitespace
    if fields.len > 0:
      actual.add fields[^1]
  actual.sort()
  var sortedExpected = expected
  sortedExpected.sort()
  if actual != sortedExpected:
    raise newException(OSError,
      "dynamic library exports do not match the BIF-derived export list")

proc buildProducer() =
  buildNativeDynlibTool()
  compileProducerBackend()
  runCommand([toolBinary, "root", producerCache, producerSource, exportList])
  compileProducerBackend()
  if hostOS == "linux":
    runCommand([toolBinary, "pic", producerCache, nimLibDir, exampleDir])
  archiveProducerObjects()
  runCommand([toolBinary, "promote", privateArchive, publicArchive, exportList])
  runCommand([toolBinary, "link", publicArchive, library, exportList])
  verifyExports()
  producerArtifactsExist()

proc generateBindings() =
  producerArtifactsExist()
  runNim([
    "c", "-d:release", "--hints:off", "--path:" & projectDir,
    "--nimcache:" & generatorCache, "--out:" & generatorBinary,
    generatorSource
  ])
  runCommand([
    generatorBinary, producerCache, exampleDir, producerSource, bindings,
    library
  ])

proc buildConsumer() =
  if not fileExists(bindings):
    raise newException(IOError,
      "generated bindings are missing; run `nim bindings` first")
  runNim([
    "c", "--mm:orc", "-d:useMalloc", "--nimcache:" & consumerCache,
    "--out:" & consumerBinary, consumerSource
  ])

proc runConsumer() =
  runCommand([consumerBinary])

proc checkMoveOnlyBinding() =
  let command = quoteShellCommand([
    compiler, "c", "--hints:off", "--warnings:off", "--mm:orc",
    "-d:useMalloc", "--nimcache:" & consumerCache,
    "--out:" & path(consumerCache, "consumer_copy_should_fail"),
    path(exampleDir, "consumer_copy_should_fail.nim")
  ])
  let (_, exitCode) = gorgeEx(command)
  if exitCode == 0:
    raise newException(OSError,
      "copying a generated move-only binding unexpectedly compiled")

task producer, "Build a native-ABI dylib from ordinary public Nim procs":
  buildProducer()

task bindings, "Generate consumer bindings from BIF and C NIF":
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
