import std/[os, strutils]
import binny/native_dynlib/build

func quoteShellCommand(arguments: openArray[string]): string =
  for index, argument in arguments:
    if index > 0:
      result.add ' '
    result.add argument.quoteShell()

let
  exampleDir = currentSourcePath.parentDir
  producerBackend = getEnv("BINNY_NATIVE_BACKEND", "c").strip().toLowerAscii()
  producerSource = exampleDir / "producer.nim"
  consumerSource = exampleDir / "consumer.nim"
  consumerBinary = exampleDir / "consumer"
  bindings = exampleDir / "generated" / "producer_abi.nim"

var nativeBuild = initNativeDynlibBuildConfig(
  producerSource,
  "libproducer",
  buildRoot = exampleDir / "nimcache",
  sourceRoot = exampleDir,
  bindingsPath = bindings,
  exportConfigPath = exampleDir / "native_dynlib.json",
  backend = producerBackend,
)
nativeBuild.nimArgs = @["--mm:orc", "-d:useMalloc"]

let
  consumerCache = nativeBuild.nativeBuildDir / "consumer"
  library = nativeBuild.nativeLibraryPath
  privateArchive = nativeBuild.nativePrivateArchivePath

proc runNim(arguments: openArray[string]) =
  var command = @[nativeBuild.compiler]
  command.add arguments
  exec quoteShellCommand(command)

proc runCommand(arguments: openArray[string]) =
  exec quoteShellCommand(arguments)

proc producerArtifactsExist() =
  if not fileExists(library) or not fileExists(nativeBuild.nativePublicArchivePath) or
      not fileExists(nativeBuild.nativeExportListPath):
    raise
      newException(IOError, "producer artifacts are missing; run `nim producer` first")

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
  nativeBuild.buildNativeDynlib()
  verifyDeadCodeElimination()
  producerArtifactsExist()

proc generateBindings() =
  producerArtifactsExist()
  nativeBuild.generateNativeDynlibBindings()
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
      nativeBuild.compiler,
      "c",
      "--hints:off",
      "--warnings:off",
      "--mm:orc",
      "-d:useMalloc",
      "--nimcache:" & consumerCache,
      "--out:" & (consumerCache / "consumer_copy_should_fail"),
      exampleDir / "consumer_copy_should_fail.nim",
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
