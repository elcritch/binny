import std/[os, strutils]
import binny/native_dynlib/exportconfig
import binny/native_dynlib/staticlib

proc usage() {.noreturn.} =
  quit """
usage:
  native_dynlib prepare NIMCACHE SOURCE_ROOT MAIN_SOURCE C_ROOT [--config:CONFIG]
  native_dynlib exports NIMCACHE SOURCE_ROOT MAIN_SOURCE LIBRARY EXPORT_LIST [--config:CONFIG]
  native_dynlib root NIMCACHE MAIN_SOURCE LIBRARY EXPORT_LIST [--config:CONFIG]
  native_dynlib pic NIMCACHE
  native_dynlib promote INPUT.a OUTPUT.a EXPORT_LIST
  native_dynlib link INPUT.a OUTPUT_LIBRARY EXPORT_LIST [LINKER_ARG ...]
"""

type NativeExportControl = object
  initSymbol: string
  symbols: seq[NativeExportSymbol]

proc loadConfigArgument(value: string): NativeExportConfig =
  for prefix in ["--config:", "--config="]:
    if value.startsWith(prefix) and value.len > prefix.len:
      return loadNativeExportConfig(value[prefix.len ..^ 1])
  quit "invalid native export config option: " & value

proc addExport(result: var NativeExportControl, name: string) =
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
        result.addExport(name[1 ..^ 1])
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
  of "prepare":
    if paramCount() notin {5, 6}:
      usage()
    let exportConfig =
      if paramCount() == 6:
        loadConfigArgument(paramStr(6))
      else:
        NativeExportConfig()
    let backend = prepareNativeRoutines(
      paramStr(2), paramStr(3), paramStr(4), paramStr(5), exportConfig
    )
    case backend
    of ncbC:
      echo "generated C-backend roots: ", paramStr(5)
    of ncbIncremental:
      echo "rooted incremental C NIF definitions"
  of "exports":
    if paramCount() notin {6, 7}:
      usage()
    let exportConfig =
      if paramCount() == 7:
        loadConfigArgument(paramStr(7))
      else:
        NativeExportConfig()
    let
      mainSource = paramStr(4)
      symbols = nativeExportSymbols(paramStr(2), paramStr(3), exportConfig)
      bifPath = findSemanticBifPath(paramStr(2), mainSource)
      initSymbol = nativeInitSymbol(paramStr(5), bifPath)
    writeNativeExportList(paramStr(6), initSymbol, symbols)
    echo "NimMain -> ", initSymbol
    for symbol in symbols:
      echo symbol.nifSymbol, " -> ", symbol.cSymbol
  of "root":
    if paramCount() notin {5, 6}:
      usage()
    let mainSource = paramStr(3)
    let
      exportConfig =
        if paramCount() == 6:
          loadConfigArgument(paramStr(6))
        else:
          NativeExportConfig()
      symbols =
        rootPublicRoutines(paramStr(2), mainSource.parentDir, mainSource, exportConfig)
      bifPath = findSemanticBifPath(paramStr(2), mainSource)
      initSymbol = nativeInitSymbol(paramStr(4), bifPath)
    writeNativeExportList(paramStr(5), initSymbol, symbols)
    echo "NimMain -> ", initSymbol
    for symbol in symbols:
      echo symbol.nifSymbol, " -> ", symbol.cSymbol
  of "pic":
    if paramCount() != 2:
      usage()
    when defined(linux) or defined(freebsd):
      compileElfPicObjects(paramStr(2))
    else:
      quit "PIC object recompilation is only needed on ELF platforms"
  of "promote":
    if paramCount() != 4:
      usage()
    let control = readExportList(paramStr(4))
    promoteNativeArchive(paramStr(2), paramStr(3), control.symbols)
  of "link":
    if paramCount() < 4:
      usage()
    let control = readExportList(paramStr(4))
    var linkerArgs: seq[string]
    for index in 5 .. paramCount():
      linkerArgs.add paramStr(index)
    linkNativeDynlib(
      paramStr(2), paramStr(3), paramStr(4), control.initSymbol, linkerArgs = linkerArgs
    )
  else:
    usage()
except NativeStaticLibError as error:
  quit error.msg
except NativeExportConfigError as error:
  quit error.msg
