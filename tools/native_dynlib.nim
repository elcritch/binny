import std/[os, strutils]
import binny/native_dynlib/staticlib

proc usage() {.noreturn.} =
  quit """
usage:
  native_dynlib root NIMCACHE MAIN_SOURCE EXPORT_LIST
  native_dynlib pic NIMCACHE NIM_INCLUDE SOURCE_ROOT
  native_dynlib promote INPUT.a OUTPUT.a EXPORT_LIST
  native_dynlib link INPUT.a OUTPUT_LIBRARY EXPORT_LIST
"""

proc readExportList(path: string): seq[NativeExportSymbol] =
  when defined(macosx):
    for line in path.readFile.splitLines:
      let name = line.strip
      if name.len > 0 and name != "_NimMain":
        if name[0] != '_':
          quit "invalid Darwin export name: " & name
        result.add NativeExportSymbol(cSymbol: name[1..^1])
  elif defined(linux) or defined(freebsd):
    var inGlobalSection = false
    for line in path.readFile.splitLines:
      let value = line.strip
      if value == "global:":
        inGlobalSection = true
      elif value == "local:":
        inGlobalSection = false
      elif inGlobalSection and value.endsWith(";"):
        let name = value[0 ..< value.high].strip
        if name.len > 0 and name != "NimMain":
          result.add NativeExportSymbol(cSymbol: name)
  else:
    quit "native dynamic libraries are unsupported on " & hostOS

if paramCount() != 4:
  usage()

try:
  case paramStr(1)
  of "root":
    let mainSource = paramStr(3)
    let symbols = rootPublicRoutines(
      paramStr(2), mainSource.parentDir, mainSource)
    writeNativeExportList(paramStr(4), symbols)
    for symbol in symbols:
      echo symbol.nifSymbol, " -> ", symbol.cSymbol
  of "pic":
    when defined(linux) or defined(freebsd):
      compileElfPicObjects(paramStr(2), [paramStr(3), paramStr(4)])
    else:
      quit "PIC recompilation is only required on ELF hosts"
  of "promote":
    promoteNativeArchive(paramStr(2), paramStr(3),
      readExportList(paramStr(4)))
  of "link":
    linkNativeDynlib(paramStr(2), paramStr(3), paramStr(4))
  else:
    usage()
except NativeStaticLibError as error:
  quit error.msg
