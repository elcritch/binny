## Reusable NimScript orchestration for BIF-derived native dynamic libraries.
##
## Import this module from ``config.nims``. Projects provide their producer,
## export configuration, compiler arguments, and any platform linker arguments;
## Binny owns the two compiler passes, archive construction, symbol promotion,
## filtered dynamic-library link, and binding generation.

when not defined(nimscript):
  {.error: "binny/native_dynlib/build is intended for config.nims".}

import std/[algorithm, json, os, strutils]

type
  NativeDynlibBuildError* = object of CatchableError

  NativeDynlibBuildConfig* = object
    ## User-controlled inputs for one native dynamic-library build.
    sourcePath*: string
    sourceRoot*: string
    buildRoot*: string
    libraryName*: string
    bindingsPath*: string
    exportConfigPath*: string
    compiler*: string
    backend*: string
    nimArgs*: seq[string]
    linkerArgs*: seq[string]
    libraryNameStrdefine*: bool

const binnyProjectDir = currentSourcePath.parentDir.parentDir.parentDir

proc fail(message: string) {.noreturn.} =
  raise newException(NativeDynlibBuildError, message)

func nativeLibrarySuffix(): string =
  case hostOS
  of "macosx":
    ".dylib"
  of "linux", "freebsd":
    ".so"
  else:
    ""

proc absoluteProjectPath(path: string): string =
  if path.isAbsolute():
    result = path
  else:
    result = absolutePath(path)
  normalizePath(result)

proc initNativeDynlibBuildConfig*(
    sourcePath, libraryName: string,
    buildRoot = ".nimcache/native_dynlib",
    sourceRoot = "",
    bindingsPath = "",
    exportConfigPath = "",
    backend = "",
    compiler = "",
): NativeDynlibBuildConfig =
  ## Creates a native-dynlib build with normal ``nim c`` as the default backend.
  ##
  ## ``buildRoot`` receives a backend-specific subdirectory. A bare
  ## ``libraryName`` receives the platform dynamic-library suffix.
  result.sourcePath =
    if sourcePath.len > 0: absoluteProjectPath(sourcePath) else: ""
  result.sourceRoot =
    if sourceRoot.len > 0:
      absoluteProjectPath(sourceRoot)
    elif result.sourcePath.parentDir.len > 0:
      result.sourcePath.parentDir
    else:
      absoluteProjectPath(".")
  result.buildRoot = absoluteProjectPath(buildRoot)
  result.libraryName =
    if libraryName.len == 0:
      ""
    elif libraryName.splitFile.ext.len == 0:
      libraryName & nativeLibrarySuffix()
    else:
      libraryName
  result.bindingsPath =
    if bindingsPath.len > 0: absoluteProjectPath(bindingsPath) else: ""
  result.exportConfigPath =
    if exportConfigPath.len > 0: absoluteProjectPath(exportConfigPath) else: ""
  result.backend =
    if backend.len > 0:
      backend.strip().toLowerAscii()
    else:
      "c"
  result.compiler =
    if compiler.len > 0:
      compiler
    else:
      getCurrentCompilerExe()

func nativeBuildDir*(config: NativeDynlibBuildConfig): string =
  ## Returns the backend-specific artifact directory.
  config.buildRoot / config.backend

func nativeLibraryPath*(config: NativeDynlibBuildConfig): string =
  ## Returns the generated dynamic-library path.
  config.nativeBuildDir / config.libraryName

func nativePrivateArchivePath*(config: NativeDynlibBuildConfig): string =
  ## Returns the unpromoted archive path, primarily for diagnostics and tests.
  let stem = config.libraryName.splitFile.name
  config.nativeBuildDir / (stem & ".private.a")

func nativePublicArchivePath*(config: NativeDynlibBuildConfig): string =
  ## Returns the archive containing promoted API symbols.
  config.nativeBuildDir / (config.libraryName.splitFile.name & ".a")

func nativeExportListPath*(config: NativeDynlibBuildConfig): string =
  ## Returns the platform linker export-control path.
  config.nativeBuildDir / (config.libraryName.splitFile.name & ".exports")

func quoteShellCommand(arguments: openArray[string]): string =
  for index, argument in arguments:
    if index > 0:
      result.add ' '
    result.add argument.quoteShell()

proc runCommand(arguments: openArray[string]) =
  exec quoteShellCommand(arguments)

proc runNim(config: NativeDynlibBuildConfig, arguments: openArray[string]) =
  var command = @[config.compiler]
  command.add arguments
  runCommand(command)

proc validate(config: NativeDynlibBuildConfig) =
  if config.backend notin ["c", "ic"]:
    fail("native dynlib backend must be either 'c' or 'ic'")
  if config.sourcePath.len == 0:
    fail("native dynlib source path cannot be empty")
  if not fileExists(config.sourcePath):
    fail("native dynlib source is missing: " & config.sourcePath)
  if config.libraryName.len == 0:
    fail("native dynlib library name cannot be empty")
  if config.exportConfigPath.len > 0 and not fileExists(config.exportConfigPath):
    fail("native dynlib export config is missing: " & config.exportConfigPath)
  if nativeLibrarySuffix().len == 0:
    fail("native dynamic libraries are unsupported on " & hostOS)

func producerCache(config: NativeDynlibBuildConfig): string =
  config.nativeBuildDir / "producer"

func toolCache(config: NativeDynlibBuildConfig): string =
  config.nativeBuildDir / "tool"

func toolBinary(config: NativeDynlibBuildConfig): string =
  config.toolCache / "native_dynlib"

func backendOutput(config: NativeDynlibBuildConfig): string =
  config.producerCache / "native_backend"

func cRootSource(config: NativeDynlibBuildConfig): string =
  config.producerCache / "binny_native_root.nim"

func toolSource(): string =
  binnyProjectDir / "tools/native_dynlib.nim"

proc compileProducer(
    config: NativeDynlibBuildConfig, sourcePath: string, force = false
) =
  var arguments = @[config.backend]
  arguments.add config.nimArgs
  arguments.add [
    "--genBif:on",
    "--app:staticlib",
    "--nimcache:" & config.producerCache,
    "--out:" & config.backendOutput,
  ]
  if force:
    arguments.add "-f"
  if config.backend == "c" and hostOS in ["linux", "freebsd"]:
    arguments.add "--passC:-fPIC"
  arguments.add sourcePath
  config.runNim(arguments)

proc buildTool(config: NativeDynlibBuildConfig) =
  if not fileExists(toolSource()):
    fail("Binny native dynlib tool is missing: " & toolSource())
  config.runNim(
    [
      "c",
      "-d:release",
      "--hints:off",
      "--path:" & binnyProjectDir,
      "--nimcache:" & config.toolCache,
      "--out:" & config.toolBinary,
      toolSource(),
    ]
  )

proc toolArguments(
    config: NativeDynlibBuildConfig, command: string
): seq[string] =
  result = @[config.toolBinary, command]

proc addExportConfig(
    arguments: var seq[string], config: NativeDynlibBuildConfig
) =
  if config.exportConfigPath.len > 0:
    arguments.add "--config:" & config.exportConfigPath

proc prepareRoutines(config: NativeDynlibBuildConfig) =
  var arguments = config.toolArguments("prepare")
  arguments.add [
    config.producerCache,
    config.sourceRoot,
    config.sourcePath,
    config.cRootSource,
  ]
  arguments.addExportConfig(config)
  runCommand(arguments)

proc writeExportList(config: NativeDynlibBuildConfig) =
  var arguments = config.toolArguments("exports")
  arguments.add [
    config.producerCache,
    config.sourceRoot,
    config.sourcePath,
    config.nativeLibraryPath,
    config.nativeExportListPath,
  ]
  arguments.addExportConfig(config)
  runCommand(arguments)

proc makeIncrementalObjectsPic(config: NativeDynlibBuildConfig) =
  if config.backend == "ic" and hostOS in ["linux", "freebsd"]:
    runCommand(config.toolArguments("pic") & @[config.producerCache])

proc producerObjects(config: NativeDynlibBuildConfig): seq[string] =
  if config.backend == "c":
    let descriptionPath = config.backendOutput & ".json"
    if not fileExists(descriptionPath):
      fail("Nim C build description is missing: " & descriptionPath)
    let description = parseJson(readFile(descriptionPath))
    if not description.hasKey("link"):
      fail("Nim C build description has no link object list: " & descriptionPath)
    for node in description["link"]:
      let path = node.getStr()
      if path.endsWith(".o") and path notin result:
        result.add path
  else:
    for path in listFiles(config.producerCache):
      if path.endsWith(".o"):
        result.add path
  result.sort()
  if result.len == 0:
    fail("native dynlib producer emitted no object files")

proc archiveObjects(config: NativeDynlibBuildConfig) =
  let archive = config.nativePrivateArchivePath
  if fileExists(archive):
    rmFile(archive)
  var command =
    case hostOS
    of "macosx":
      @["/usr/bin/libtool", "-static", "-o", archive]
    of "linux", "freebsd":
      @["ar", "-rcs", archive]
    else:
      @[]
  command.add config.producerObjects()
  runCommand(command)

proc promoteAndLink(config: NativeDynlibBuildConfig) =
  runCommand(
    config.toolArguments("promote") &
      @[
        config.nativePrivateArchivePath,
        config.nativePublicArchivePath,
        config.nativeExportListPath,
      ]
  )
  var arguments = config.toolArguments("link")
  arguments.add [
    config.nativePublicArchivePath,
    config.nativeLibraryPath,
    config.nativeExportListPath,
  ]
  arguments.add config.linkerArgs
  runCommand(arguments)

proc expectedExports(config: NativeDynlibBuildConfig): seq[string] =
  var inGlobalSection = false
  for line in readFile(config.nativeExportListPath).splitLines():
    let value = line.strip()
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
        let name = value[0 ..< value.high].strip()
        if name.len > 0:
          result.add name
    else:
      discard

proc verifyExports(config: NativeDynlibBuildConfig) =
  let command =
    case hostOS
    of "macosx":
      @["/usr/bin/nm", "-gU", config.nativeLibraryPath]
    of "linux", "freebsd":
      @["nm", "-D", "--defined-only", config.nativeLibraryPath]
    else:
      @[]
  let (output, exitCode) = gorgeEx(quoteShellCommand(command))
  if exitCode != 0:
    fail("nm failed for the generated native library:\n" & output)
  var actual: seq[string]
  for line in output.splitLines():
    let fields = line.splitWhitespace()
    if fields.len > 0:
      actual.add fields[^1]
  actual.sort()
  var expected = config.expectedExports()
  expected.sort()
  if actual != expected:
    fail("native library exports do not match the BIF-derived export list")

proc buildNativeDynlib*(config: NativeDynlibBuildConfig) =
  ## Builds, promotes, links, and verifies one BIF-derived native dynlib.
  config.validate()
  mkDir(config.nativeBuildDir)
  config.buildTool()
  config.compileProducer(config.sourcePath)
  config.prepareRoutines()
  if config.backend == "c":
    config.compileProducer(config.cRootSource, force = true)
  else:
    config.compileProducer(config.sourcePath)
  config.writeExportList()
  config.makeIncrementalObjectsPic()
  config.archiveObjects()
  config.promoteAndLink()
  config.verifyExports()

proc generateNativeDynlibBindings*(
    config: NativeDynlibBuildConfig,
    outputPath = "",
    libraryPath = "",
) =
  ## Generates bindings for a completed native dynlib.
  config.validate()
  let
    output = if outputPath.len > 0: outputPath else: config.bindingsPath
    library = if libraryPath.len > 0: libraryPath else: config.nativeLibraryPath
  if output.len == 0:
    fail("native dynlib bindings path cannot be empty")
  config.buildTool()
  var arguments = config.toolArguments("bindings")
  arguments.add [
    config.producerCache,
    config.sourceRoot,
    config.sourcePath,
    library,
    output,
  ]
  arguments.addExportConfig(config)
  if config.libraryNameStrdefine:
    arguments.add "--library-strdefine"
  runCommand(arguments)

proc buildNativeDynlibAndBindings*(config: NativeDynlibBuildConfig) =
  ## Builds the native dynlib and generates its consumer binding module.
  config.buildNativeDynlib()
  config.generateNativeDynlibBindings()

proc stageNativeDynlib*(config: NativeDynlibBuildConfig, outputDir: string) =
  ## Copies a completed library and generates matching bindings in ``outputDir``.
  config.validate()
  if config.bindingsPath.len == 0:
    fail("native dynlib bindings path cannot be empty when staging")
  let absoluteOutputDir = absoluteProjectPath(outputDir)
  mkDir(absoluteOutputDir)
  let
    stagedLibrary = absoluteOutputDir / config.libraryName
    stagedBindings = absoluteOutputDir / config.bindingsPath.extractFilename
    loaderPath = outputDir / config.libraryName
  cpFile(config.nativeLibraryPath, stagedLibrary)
  config.generateNativeDynlibBindings(stagedBindings, loaderPath)
