## Generates native Nim dynamic-library bindings from compiler ABI artifacts.
##
## The required NIF/BIF reader support is vendored in ``native_dynlib/nif``.

import std/[os, syncio]
import native_dynlib/[artifacts, bifreader]

type
  NativeBindingsConfig* = object
    ## Paths and loader settings used to generate one binding module.
    sourcePath*: string
    manifestPath*: string
    nimcacheDir*: string
    libraryOverride*: string
    sourceRoot*: string
    bifDerived*: bool

proc initNativeBindingsConfig*(sourcePath, manifestPath: string;
    nimcacheDir = ""; libraryOverride = ""): NativeBindingsConfig =
  ## Creates binding-generator configuration.
  ##
  ## ``nimcacheDir`` defaults to the manifest's directory. The generated module
  ## uses the relocatable library name recorded in the manifest unless
  ## ``libraryOverride`` supplies another loader name or path.
  result.sourcePath = sourcePath
  result.manifestPath = manifestPath
  result.libraryOverride = libraryOverride
  if nimcacheDir.len > 0:
    result.nimcacheDir = nimcacheDir
  else:
    result.nimcacheDir = manifestPath.parentDir
    if result.nimcacheDir.len == 0:
      result.nimcacheDir = "."

proc initBifNativeBindingsConfig*(sourcePath, nimcacheDir,
    libraryName: string; sourceRoot = ""): NativeBindingsConfig =
  ## Creates configuration for bindings reconstructed from BIF and C NIF.
  result.sourcePath = sourcePath
  result.nimcacheDir = nimcacheDir
  result.libraryOverride = libraryName
  result.bifDerived = true
  if sourceRoot.len > 0:
    result.sourceRoot = sourceRoot
  else:
    result.sourceRoot = sourcePath.parentDir
    if result.sourceRoot.len == 0:
      result.sourceRoot = "."

proc generateNativeBindings*(config: NativeBindingsConfig): string =
  ## Returns a Nim module for either manifest or BIF-derived native exports.
  ##
  ## ``nimcacheDir`` must contain the matching semantic BIF. BIF-derived mode
  ## also reads incremental ``.c.nif`` definitions for exact import names.
  ## ``sourcePath`` identifies the library's root Nim module.
  let api =
    if config.bifDerived:
      readBifNativeApi(
        config.nimcacheDir,
        config.sourceRoot,
        config.sourcePath,
        config.libraryOverride,
      )
    else:
      let bifPath = findSemanticBif(config.nimcacheDir, config.sourcePath)
      readNativeApi(bifPath, config.manifestPath)
  result = generateNativeModule(api, config.libraryOverride)

proc generateNativeBindings*(nimcacheDir, sourcePath, manifestPath: string;
    libraryOverride = ""): string =
  ## Compatibility overload for callers that pass individual paths.
  result = generateNativeBindings(initNativeBindingsConfig(
    sourcePath, manifestPath, nimcacheDir, libraryOverride))

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
