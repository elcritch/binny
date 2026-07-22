import std/[os, strutils]
import binny/native_dynlib/staticlib

proc usage() {.noreturn.} =
  quit """
usage:
  native_dynlib root NIMCACHE MAIN_SOURCE LIBRARY EXPORT_LIST
  native_dynlib pic NIMCACHE NIM_INCLUDE SOURCE_ROOT
  native_dynlib promote INPUT.a OUTPUT.a EXPORT_LIST
  native_dynlib link INPUT.a OUTPUT_LIBRARY EXPORT_LIST
"""

type NativeExportControl = object
  initSymbol: string
  symbols: seq[NativeExportSymbol]

proc addExport(result: var NativeExportControl; name: string) =
  if result.initSymbol.len == 0:
    if "_NimMain_" notin name:
      quit "invalid native initializer export: " & name
    result.initSymbol = name
  else:
    result.symbols.add NativeExportSymbol(cSymbol: name)

proc readExportList(path: string): NativeExportControl =
  when defined(macosx):
    for line in path.readFile.splitLines:
      let name = line.strip
      if name.len > 0:
        if name[0] != '_':
          quit "invalid Darwin export name: " & name
        result.addExport(name[1..^1])
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
        if name.len > 0:
          result.addExport(name)
  else:
    quit "native dynamic libraries are unsupported on " & hostOS
  if result.initSymbol.len == 0:
    quit "native export list has no initializer"

if paramCount() == 0:
  usage()

try:
  case paramStr(1)
  of "root":
    if paramCount() != 5:
      usage()
    let mainSource = paramStr(3)
    let
      symbols = rootPublicRoutines(
        paramStr(2), mainSource.parentDir, mainSource)
      bifPath = findSemanticBifPath(paramStr(2), mainSource)
      initSymbol = nativeInitSymbol(paramStr(4), bifPath)
    writeNativeExportList(paramStr(5), initSymbol, symbols)
    echo "NimMain -> ", initSymbol
    for symbol in symbols:
      echo symbol.nifSymbol, " -> ", symbol.cSymbol
  of "pic":
    if paramCount() != 4:
      usage()
    when defined(linux) or defined(freebsd):
      compileElfPicObjects(paramStr(2), [paramStr(3), paramStr(4)])
    else:
      quit "PIC recompilation is only required on ELF hosts"
  of "promote":
    if paramCount() != 4:
      usage()
    let control = readExportList(paramStr(4))
    promoteNativeArchive(paramStr(2), paramStr(3), control.symbols)
  of "link":
    if paramCount() != 4:
      usage()
    let control = readExportList(paramStr(4))
    linkNativeDynlib(
      paramStr(2), paramStr(3), paramStr(4), control.initSymbol)
  else:
    usage()
except NativeStaticLibError as error:
  quit error.msg
