import std/os
import binny/native_dynlib

if paramCount() != 4:
  quit "usage: generate NIMCACHE SOURCE MANIFEST OUTPUT"

let
  nimcacheDir = paramStr(1)
  sourcePath = paramStr(2)
  manifestPath = paramStr(3)
  outputPath = paramStr(4)
  config = initNativeBindingsConfig(
    sourcePath, manifestPath, nimcacheDir)

discard config.writeNativeBindings(outputPath)
