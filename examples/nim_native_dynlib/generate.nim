import std/os
import binny/native_dynlib

if paramCount() notin {5, 6}:
  quit "usage: generate NIMCACHE SOURCE_ROOT SOURCE OUTPUT LIBRARY [CONFIG]"

let
  nimcacheDir = paramStr(1)
  sourceRoot = paramStr(2)
  sourcePath = paramStr(3)
  outputPath = paramStr(4)
  libraryName = paramStr(5)
  exportConfig =
    if paramCount() == 6: loadNativeExportConfig(paramStr(6))
    else: NativeExportConfig()
  config = initBifNativeBindingsConfig(
    sourcePath, nimcacheDir, libraryName, sourceRoot, exportConfig)

discard config.writeNativeBindings(outputPath)
