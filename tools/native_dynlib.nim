import std/[os, strutils]
import binny/native_dynlib/staticlib

proc usage() {.noreturn.} =
  quit """
usage:
  native_dynlib root NIMCACHE MAIN_SOURCE EXPORT_LIST
  native_dynlib promote INPUT.a OUTPUT.a EXPORT_LIST
  native_dynlib link INPUT.a OUTPUT.dylib EXPORT_LIST
"""

proc readExportList(path: string): seq[NativeExportSymbol] =
  for line in path.readFile.splitLines:
    let name = line.strip
    if name.len > 0 and name != "_NimMain":
      if name[0] != '_':
        quit "invalid Darwin export name: " & name
      result.add NativeExportSymbol(cSymbol: name[1..^1])

if paramCount() != 4:
  usage()

try:
  case paramStr(1)
  of "root":
    let mainSource = paramStr(3)
    let symbols = rootPublicRoutines(
      paramStr(2), mainSource.parentDir, mainSource)
    writeDarwinExportList(paramStr(4), symbols)
    for symbol in symbols:
      echo symbol.nifSymbol, " -> ", symbol.cSymbol
  of "promote":
    promoteMachOArchive(paramStr(2), paramStr(3), readExportList(paramStr(4)))
  of "link":
    linkMachODylib(paramStr(2), paramStr(3), paramStr(4))
  else:
    usage()
except NativeStaticLibError as error:
  quit error.msg
