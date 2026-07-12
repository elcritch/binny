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

proc generateNativeBindings*(config: NativeBindingsConfig): string =
  ## Returns a Nim module that binds the ABI exports described by ``manifestPath``.
  ##
  ## ``nimcacheDir`` must contain the semantic BIF files produced alongside the
  ## library with ``--emitBif:on``. ``sourcePath`` identifies the library's root
  ## Nim module. Relative input paths are resolved against the caller's current
  ## directory.
  let
    bifPath = findSemanticBif(config.nimcacheDir, config.sourcePath)
    api = readNativeApi(bifPath, config.manifestPath)
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
