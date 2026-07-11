import std/[os, syncio]
import binny/native_dynlib

proc writeFileStable(path, content: string) =
  let previous =
    try: readFile(path)
    except IOError: ""
  if previous != content:
    writeFile(path, content)

if paramCount() != 5:
  quit "usage: generate NIMCACHE SOURCE MANIFEST LIBRARY OUTPUT"

let
  nimcacheDir = paramStr(1)
  sourcePath = paramStr(2)
  manifestPath = paramStr(3)
  libraryPath = paramStr(4)
  outputPath = paramStr(5)

createDir(outputPath.parentDir)
writeFileStable(outputPath, generateNativeBindings(
  nimcacheDir, sourcePath, manifestPath, libraryPath))
