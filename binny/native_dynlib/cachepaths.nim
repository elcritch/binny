import std/[os, strutils]

proc incrementalBackendDir*(nimcacheDir: string): string =
  ## The IC driver records the active configuration and entry point here.
  let stamp = nimcacheDir / "ic_link_args.txt"
  if fileExists(stamp):
    let path = readFile(stamp).splitLines()[0]
    if dirExists(path):
      return path
  result = nimcacheDir
