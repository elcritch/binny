import std/os
import binny/native_dynlib

if paramCount() != 5:
  quit "usage: generate NIMCACHE SOURCE_ROOT SOURCE OUTPUT LIBRARY"

let
  nimcacheDir = paramStr(1)
  sourceRoot = paramStr(2)
  sourcePath = paramStr(3)
  outputPath = paramStr(4)
  libraryName = paramStr(5)
  config = initBifNativeBindingsConfig(
    sourcePath, nimcacheDir, libraryName, sourceRoot)

discard config.writeNativeBindings(outputPath)
