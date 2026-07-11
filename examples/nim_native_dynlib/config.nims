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
  generatedDir = path(exampleDir, "generated")
  producerSource = path(exampleDir, "producer.nim")
  consumerSource = path(exampleDir, "consumer.nim")
  generatorSource = path(exampleDir, "generate.nim")
  library = case hostOS
    of "macosx": path(nimcacheDir, "libproducer.dylib")
    of "linux": path(nimcacheDir, "libproducer.so")
    else: raise newException(ValueError,
      "native dynlib example supports only macOS and Linux")
  manifest = path(nimcacheDir, "libproducer.abi.nif")
  bindings = path(generatedDir, "producer_abi.nim")
  consumerBinary = path(nimcacheDir, "consumer")
  generatorCache = path(nimcacheDir, "generator")
  generatorBinary = path(generatorCache, "generate")

proc runNim(args: openArray[string]) =
  var command = @[compiler]
  for arg in args:
    command.add arg
  exec quoteShellCommand(command)

proc producerArtifactsExist() =
  if not fileExists(library) or not fileExists(manifest):
    raise newException(IOError,
      "producer artifacts are missing; run `nim producer` first")

proc buildProducer() =
  runNim([
    "c", "--experimental:abi", "--emitBif:on", "--app:lib", "--mm:orc",
    "-d:useMalloc", "--nimcache:" & nimcacheDir, "--out:" & library,
    producerSource
  ])
  producerArtifactsExist()

proc generateBindings() =
  producerArtifactsExist()
  runNim([
    "r", "-d:release", "--path:" & projectDir,
    "--nimcache:" & generatorCache, "--out:" & generatorBinary,
    generatorSource, nimcacheDir, producerSource, manifest, library, bindings
  ])

proc buildConsumer() =
  if not fileExists(bindings):
    raise newException(IOError,
      "generated bindings are missing; run `nim bindings` first")
  runNim([
    "c", "--mm:orc", "-d:useMalloc", "--nimcache:" & nimcacheDir,
    "--out:" & consumerBinary, consumerSource
  ])

proc runConsumer() =
  exec quoteShellCommand([consumerBinary])

proc checkMoveOnlyBinding() =
  let command = quoteShellCommand([
    compiler, "c", "--hints:off", "--warnings:off", "--mm:orc",
    "-d:useMalloc", "--nimcache:" & nimcacheDir,
    "--out:" & path(nimcacheDir, "consumer_copy_should_fail"),
    path(exampleDir, "consumer_copy_should_fail.nim")
  ])
  let (_, exitCode) = gorgeEx(command)
  if exitCode == 0:
    raise newException(OSError,
      "copying a generated move-only binding unexpectedly compiled")

task producer, "Build the producer dynamic library and ABI artifacts":
  buildProducer()

task bindings, "Generate bindings for the existing producer library":
  generateBindings()

task consumer, "Generate bindings, build the consumer, and run it":
  generateBindings()
  buildConsumer()
  runConsumer()

task build, "Build the producer, generated bindings, and consumer":
  buildProducer()
  generateBindings()
  buildConsumer()

task nativeDynlibTest, "Build and run the complete native dynamic-library example":
  buildTask()
  runConsumer()
  checkMoveOnlyBinding()

task e2e, "Alias for the complete native dynamic-library example":
  nativeDynlibTestTask()
