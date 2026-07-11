import std/[strutils, tables]
import model

type
  NativeArtifactError* = object of ValueError

func nimIdentifier(value: string): string =
  "`" & value.replace("`", "") & "`"

proc typeNames(api: NativeApi): Table[string, string] =
  for typ in api.types:
    result[typ.nifSymbol] = typ.name
    result[typ.typeId] = typ.name

func builtinTypeId(symbol: string): string =
  if not symbol.startsWith("`t"):
    return
  let dot = symbol.find('.')
  if dot < 3:
    return
  case parseInt(symbol[2 ..< dot])
  of 1: "bool"
  of 2: "char"
  of 26: "pointer"
  of 28: "string"
  of 29: "cstring"
  of 31: "int"
  of 32: "int8"
  of 33: "int16"
  of 34: "int32"
  of 35: "int64"
  of 36: "float"
  of 37: "float32"
  of 38: "float64"
  of 40: "uint"
  of 41: "uint8"
  of 42: "uint16"
  of 43: "uint32"
  of 44: "uint64"
  else: ""

proc nimType(symbol: string; names: Table[string, string]): string =
  if symbol.len == 0:
    return ""
  if symbol in names:
    return names[symbol]
  let builtin = builtinTypeId(symbol)
  if builtin.len > 0:
    return builtin
  let dot = symbol.find('.')
  let name = if dot < 0: symbol else: symbol[0 ..< dot]
  case name
  of "bool", "char", "string", "cstring", "pointer",
      "int", "int8", "int16", "int32", "int64",
      "uint", "uint8", "uint16", "uint32", "uint64",
      "float", "float32", "float64",
      "cchar", "cschar", "cshort", "cint", "clong", "clonglong",
      "cuchar", "cushort", "cuint", "culong", "culonglong",
      "cfloat", "cdouble", "csize_t":
    result = name
  else:
    raise newException(NativeArtifactError,
      "unsupported native ABI type symbol: " & symbol)

proc generateField(field: NativeField; names: Table[string, string];
                   indent: string): string =
  result.add indent & nimIdentifier(field.name)
  if field.exported:
    result.add "*"
  result.add ": " & nimType(field.typeSymbol, names) & "\n"

proc generateRecord(record: seq[NativeRecordPart];
                    names: Table[string, string]; indent: string): string =
  for part in record:
    case part.kind
    of nrField:
      result.add generateField(part.field, names, indent)
    of nrCase:
      result.add indent & "case " & nimIdentifier(part.discriminant.name)
      if part.discriminant.exported:
        result.add "*"
      result.add ": " & nimType(part.discriminant.typeSymbol, names) & "\n"
      for branch in part.branches:
        if branch.isElse:
          result.add indent & "else:\n"
        else:
          result.add indent & "of " & branch.selectors.join(", ") & ":\n"
        if branch.record.len == 0:
          result.add indent & "  discard\n"
        else:
          result.add generateRecord(branch.record, names, indent & "  ")

proc generateTypes(api: NativeApi; names: Table[string, string]): string =
  if api.types.len == 0:
    return
  result.add "type\n"
  for typ in api.types:
    result.add "  " & nimIdentifier(typ.name) & "*"
    var pragmas: seq[string] = @[]
    if typ.inheritable: pragmas.add "inheritable"
    if typ.packed: pragmas.add "packed"
    if typ.union: pragmas.add "union"
    if pragmas.len > 0:
      result.add " {." & pragmas.join(", ") & ".}"
    result.add " = "
    case typ.kind
    of ntObject: result.add "object"
    of ntRefObject: result.add "ref object"
    of ntEnum:
      result.add "enum\n"
      for value in typ.enumValues:
        result.add "    " & nimIdentifier(value.name) & " = " &
          $value.ordinal & "\n"
      result.add "\n"
      continue
    if typ.baseTypeSymbol.len > 0:
      result.add " of " & nimType(typ.baseTypeSymbol, names)
    result.add "\n"
    result.add generateRecord(typ.record, names, "    ")
    result.add "\n"

proc generateFieldChecks(typeName: string; record: seq[NativeRecordPart];
                         indent: string): string =
  for part in record:
    case part.kind
    of nrField:
      if part.field.offset >= 0:
        result.add indent & "doAssert offsetOf(" & typeName & ", " &
          nimIdentifier(part.field.name) & ") == " & $part.field.offset & "\n"
    of nrCase:
      if part.discriminant.offset >= 0:
        result.add indent & "doAssert offsetOf(" & typeName & ", " &
          nimIdentifier(part.discriminant.name) & ") == " &
          $part.discriminant.offset & "\n"
      for branch in part.branches:
        result.add generateFieldChecks(typeName, branch.record, indent)

proc generateLayoutChecks(api: NativeApi): string =
  if api.types.len == 0:
    return
  result.add "static:\n"
  for typ in api.types:
    let typeName = nimIdentifier(typ.name)
    if typ.size >= 0:
      result.add "  doAssert sizeof(" & typeName & ") == " & $typ.size & "\n"
    if typ.alignment >= 0:
      result.add "  doAssert alignof(" & typeName & ") == " &
        $typ.alignment & "\n"
    if typ.kind == ntObject:
      result.add generateFieldChecks(typeName, typ.record, "  ")
  result.add "\n"

func params(procInfo: NativeProc; names: Table[string, string]): string =
  var parts: seq[string] = @[]
  for param in procInfo.params:
    let modifier = if param.byVar: "var " else: ""
    parts.add nimIdentifier(param.name) & ": " & modifier &
      nimType(param.typeSymbol, names)
  result = parts.join("; ")

func args(procInfo: NativeProc): string =
  var parts: seq[string] = @[]
  for param in procInfo.params:
    parts.add nimIdentifier(param.name)
  result = parts.join(", ")

proc generateNativeModule*(api: NativeApi; libraryPath: string): string =
  if api.procs.len == 0:
    raise newException(NativeArtifactError, "no native ABI exports found")
  let names = typeNames(api)
  result.add "# Generated by nim_native_dynlib; do not edit.\n\n"
  result.add "const nativeLibrary* = " & libraryPath.escape & "\n\n"
  result.add generateTypes(api, names)
  result.add generateLayoutChecks(api)
  result.add "var nativeLibraryInitialized = false\n\n"
  result.add "proc nativeNimMain() {.cdecl, importc: " &
    api.initSymbol.escape & ", " &
    "dynlib: nativeLibrary.}\n\n"
  result.add "proc ensureNativeLibrary() {.raises: [].} =\n"
  result.add "  if not nativeLibraryInitialized:\n"
  result.add "    nativeNimMain()\n"
  result.add "    nativeLibraryInitialized = true\n\n"
  result.add "proc initNativeLibrary*() =\n"
  result.add "  if not nativeLibraryInitialized:\n"
  result.add "    echo \"Initializing native library: \", nativeLibrary\n"
  result.add "    ensureNativeLibrary()\n"
  result.add "    echo \"Native library initialized\"\n"

  for i, hook in api.hooks:
    let procInfo = hook.procInfo
    let returnType = nimType(procInfo.returnTypeSymbol, names)
    let returnDecl = if returnType.len == 0: "" else: ": " & returnType
    let formals = params(procInfo, names)
    let callArgs = args(procInfo)
    if hook.status == nhCustom:
      result.add "\nproc nativeHookRaw" & $i & "(" & formals & ")" &
        returnDecl & " {.nimcall, importc: " & procInfo.cSymbol.escape &
        ", dynlib: nativeLibrary.}\n"
      result.add "\nproc " & nimIdentifier(hook.kind) & "(" & formals & ")" &
        returnDecl & " =\n"
      result.add "  ensureNativeLibrary()\n"
      if returnType.len == 0:
        result.add "  nativeHookRaw" & $i & "(" & callArgs & ")\n"
      else:
        result.add "  result = nativeHookRaw" & $i & "(" & callArgs & ")\n"
    else:
      result.add "\nproc " & nimIdentifier(hook.kind) & "(" & formals & ")" &
        returnDecl & " {.error.}\n"

  for i, procInfo in api.procs:
    let returnType = nimType(procInfo.returnTypeSymbol, names)
    let returnDecl = if returnType.len == 0: "" else: ": " & returnType
    let formals = params(procInfo, names)
    let callArgs = args(procInfo)
    result.add "\nproc nativeRaw" & $i & "(" & formals & ")" & returnDecl &
      " {.nimcall, importc: " & procInfo.cSymbol.escape &
      ", dynlib: nativeLibrary.}\n"
    result.add "\nproc " & nimIdentifier(procInfo.name) & "*(" & formals & ")" &
      returnDecl & " =\n"
    result.add "  initNativeLibrary()\n"
    if returnType.len == 0:
      result.add "  nativeRaw" & $i & "(" & callArgs & ")\n"
    else:
      result.add "  result = nativeRaw" & $i & "(" & callArgs & ")\n"
