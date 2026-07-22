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
  consumerBinary = path(consumerCache, "consumer")
  bindings = path(generatedDir, "producer_abi.nim")
  backendOutput = path(producerCache, "producer-backend")
  privateArchive = path(nimcacheDir, "libproducer.private.a")
  publicArchive = path(nimcacheDir, "libproducer.a")
  exportList = path(nimcacheDir, "libproducer.exports")
  library = case hostOS
    of "macosx": path(nimcacheDir, "libproducer.dylib")
    else: raise newException(ValueError,
      "static-library symbol promotion currently supports only macOS")

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
  var command = @["/usr/bin/libtool", "-static", "-o", privateArchive]
  for objectPath in listFiles(producerCache):
    if objectPath.endsWith(".o"):
      command.add objectPath
  if command.len == 4:
    raise newException(IOError, "producer backend emitted no object files")
  runCommand(command)

proc verifyExports() =
  let
    (output, exitCode) = gorgeEx(quoteShellCommand(["/usr/bin/nm", "-gU", library]))
    expected = readFile(exportList).strip.splitLines
  if exitCode != 0:
    raise newException(OSError, "nm failed for the generated dylib:\n" & output)
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
      "dylib exports do not match the BIF-derived export list")

proc buildProducer() =
  buildNativeDynlibTool()
  compileProducerBackend()
  runCommand([toolBinary, "root", producerCache, producerSource, exportList])
  compileProducerBackend()
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
