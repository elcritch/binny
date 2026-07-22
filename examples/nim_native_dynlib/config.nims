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
  producerSource = path(exampleDir, "producer.nim")
  toolSource = path(projectDir, "tools/native_dynlib.nim")
  toolBinary = path(toolCache, "native_dynlib")
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

task producer, "Build a native-ABI dylib from ordinary public Nim procs":
  buildProducer()

task build, "Build the promoted static archive and dynamic library":
  buildProducer()

task nativeDynlibTest, "Build and verify the BIF-derived dylib export surface":
  buildProducer()

task e2e, "Alias for the native dynamic-library test":
  nativeDynlibTestTask()
