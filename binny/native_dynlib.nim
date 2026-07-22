## Generates native Nim dynamic-library bindings from compiler BIF and C NIF.
##
## The required NIF/BIF reader support is vendored in ``native_dynlib/nif``.

import std/[os, syncio]
import native_dynlib/[artifacts, bifreader]

type
  NativeBindingsConfig* = object
    ## Paths and loader settings used to generate one binding module.
    sourcePath*: string
    nimcacheDir*: string
    libraryName*: string
    sourceRoot*: string

func nativeLibrarySuffix(): string =
  when defined(windows):
    ".dll"
  elif defined(macosx):
    ".dylib"
  else:
    ".so"

proc initBifNativeBindingsConfig*(sourcePath, nimcacheDir,
    libraryName: string; sourceRoot = ""): NativeBindingsConfig =
  ## Creates configuration for bindings reconstructed from BIF and C NIF.
  ## A bare ``libraryName`` receives the host dynamic-library suffix.
  result.sourcePath = sourcePath
  result.nimcacheDir = nimcacheDir
  result.libraryName =
    if libraryName.splitFile.ext.len == 0:
      libraryName & nativeLibrarySuffix()
    else:
      libraryName
  if sourceRoot.len > 0:
    result.sourceRoot = sourceRoot
  else:
    result.sourceRoot = sourcePath.parentDir
    if result.sourceRoot.len == 0:
      result.sourceRoot = "."

proc generateNativeBindings*(config: NativeBindingsConfig): string =
  ## Returns a Nim module for BIF-derived native exports.
  ##
  ## ``nimcacheDir`` must contain matching semantic BIF and incremental
  ## ``.c.nif`` definitions. ``sourcePath`` identifies the root Nim module.
  let api = readBifNativeApi(
    config.nimcacheDir,
    config.sourceRoot,
    config.sourcePath,
    config.libraryName,
  )
  result = generateNativeModule(api)

proc writeNativeBindings*(config: NativeBindingsConfig;
                          outputPath: string): bool =
  ## Writes a generated binding module and returns ``true`` when it changed.
  let content = generateNativeBindings(config)
  if fileExists(outputPath) and readFile(outputPath) == content:
    return false
  let outputDir = outputPath.parentDir
  if outputDir.len > 0:
    createDir(outputDir)
  writeFile(outputPath, content)
  result = true
