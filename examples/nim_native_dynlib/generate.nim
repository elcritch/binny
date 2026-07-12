import std/os
import binny/native_dynlib

if paramCount() notin {4, 5}:
  quit "usage: generate NIMCACHE SOURCE MANIFEST OUTPUT [LIBRARY]"

let
  nimcacheDir = paramStr(1)
  sourcePath = paramStr(2)
  manifestPath = paramStr(3)
  outputPath = paramStr(4)
  libraryOverride = if paramCount() == 5: paramStr(5) else: ""
  config = initNativeBindingsConfig(
    sourcePath, manifestPath, nimcacheDir, libraryOverride)

discard config.writeNativeBindings(outputPath)
