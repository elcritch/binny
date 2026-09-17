import std/[sequtils, strutils, tables]
import model

type
  NativeArtifactError* = object of ValueError

  MangledType = object
    name: string
    arguments: seq[MangledType]

  MangledCursor = object
    value: string
    position: int

func isNimKeyword(value: string): bool =
  let normalized = value.replace("_", "").toLowerAscii
  case normalized
  of "addr", "and", "as", "asm", "atomic", "bind", "block", "break", "case", "cast",
      "concept", "const", "continue", "converter", "defer", "discard", "distinct",
      "div", "do", "elif", "else", "end", "enum", "except", "export", "finally", "for",
      "from", "func", "generic", "if", "import", "in", "include", "interface", "is",
      "isnot", "iterator", "let", "lent", "macro", "method", "mixin", "mod", "nil",
      "not", "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref",
      "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using",
      "var", "when", "while", "with", "without", "xor", "yield":
    true
  else:
    false

func isNimIdentifier(value: string): bool =
  if value.len == 0 or value[0] notin {'a' .. 'z', 'A' .. 'Z', '_'}:
    return false
  for ch in value:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
      return false
  not isNimKeyword(value)

func nimIdentifier(value: string): string =
  if value.isNimIdentifier:
    value
  else:
    "`" & value.replace("`", "") & "`"

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

func isBuiltinType(typ: NativeType): bool =
  (typ.kind != ntAlias and builtinTypeId(typ.typeId).len > 0) or
    (typ.kind == ntRange and typ.name in ["Natural", "Positive"])

func simpleBuiltinType(symbol: string): string =
  case symbol
  of "bool", "char", "string", "cstring", "pointer", "int", "int8", "int16", "int32",
      "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float", "float32",
      "float64", "cchar", "cschar", "cshort", "cint", "clong", "clonglong", "cuchar",
      "cushort", "cuint", "culong", "culonglong", "cfloat", "cdouble", "csize_t":
    result = symbol

func isAnonymousGenericType(typ: NativeType): bool =
  typ.nifSymbol.len > 0 and typ.nifSymbol == typ.typeId and
    typ.kind in {ntArray, ntSequence, ntSet}

func knownTypeExpression(symbol: string, names: Table[string, string]): string =
  if symbol.len == 0:
    return
  if symbol in names:
    return names[symbol]
  result = builtinTypeId(symbol)
  if result.len == 0:
    result = simpleBuiltinType(symbol)

proc knownProcTypeExpression(
    procInfo: NativeProc, names: Table[string, string]
): string =
  var parts: seq[string]
  for index, param in procInfo.params:
    let typeExpression = knownTypeExpression(param.typeSymbol, names)
    if typeExpression.len == 0:
      return
    let paramName =
      if param.name.len > 0: nimIdentifier(param.name) else: "arg" & $index
    let modifier = if param.byVar: "var " else: ""
    parts.add paramName & ": " & modifier & typeExpression
  result = "proc(" & parts.join("; ") & ")"
  if procInfo.returnTypeSymbol.len > 0:
    let returnType = knownTypeExpression(procInfo.returnTypeSymbol, names)
    if returnType.len == 0:
      return ""
    result.add ": " & (if procInfo.returnByVar: "var " else: "") & returnType
  if procInfo.callConv.len > 0:
    result.add " {." & procInfo.callConv & ".}"

proc typeSize(api: NativeApi, symbol: string): int64 =
  for candidate in api.types:
    if (candidate.nifSymbol == symbol or candidate.typeId == symbol) and
        candidate.size > 0:
      return candidate.size
  case builtinTypeId(symbol)
  of "bool", "char", "int8", "uint8":
    result = 1
  of "int16", "uint16":
    result = 2
  of "int32", "uint32", "float32":
    result = 4
  of "int", "uint", "int64", "uint64", "float", "float64", "pointer":
    result = 8

proc arrayLength(api: NativeApi, typ: NativeType): int64 =
  if typ.arrayLength >= 0:
    return typ.arrayLength
  if typ.indexTypeSymbol.len > 0:
    for candidate in api.types:
      if (
        candidate.nifSymbol == typ.indexTypeSymbol or
        candidate.typeId == typ.indexTypeSymbol
      ) and candidate.kind == ntEnum:
        return candidate.enumValues.len.int64
  let elementSize = api.typeSize(typ.elementTypeSymbol)
  if elementSize <= 0 or typ.size < 0 or typ.size mod elementSize != 0:
    return -1
  typ.size div elementSize

proc nimType(symbol: string, names: Table[string, string]): string

proc typeNames(api: NativeApi): Table[string, string] =
  for typ in api.types:
    if typ.isAnonymousGenericType:
      continue
    elif typ.kind in {ntProc, ntImportedGeneric, ntOpenArray}:
      continue
    elif typ.kind == ntRange and typ.name in ["Natural", "Positive"]:
      result[typ.nifSymbol] = typ.name
      result[typ.typeId] = typ.name
    elif not typ.isBuiltinType:
      let name = nimIdentifier(typ.name)
      result[typ.nifSymbol] = name
      result[typ.typeId] = name
      for symbol in typ.equivalentTypeSymbols:
        result[symbol] = name

  var changed = true
  while changed:
    changed = false
    for typ in api.types:
      if typ.typeId in result or not (
        typ.isAnonymousGenericType or
        typ.kind in {ntImportedGeneric, ntOpenArray, ntProc}
      ):
        continue
      var rendered: string
      case typ.kind
      of ntImportedGeneric:
        var arguments: seq[string]
        for argument in typ.genericArguments:
          let expression = knownTypeExpression(argument, result)
          if expression.len == 0:
            break
          arguments.add expression
        if arguments.len == typ.genericArguments.len:
          rendered = nimIdentifier(typ.name) & "[" & arguments.join(", ") & "]"
      of ntProc:
        rendered = knownProcTypeExpression(typ.procInfo, result)
      of ntSequence, ntSet, ntArray, ntOpenArray:
        let element = knownTypeExpression(typ.elementTypeSymbol, result)
        if element.len == 0:
          continue
        case typ.kind
        of ntSequence:
          rendered = "seq[" & element & "]"
        of ntSet:
          rendered = "set[" & element & "]"
        of ntOpenArray:
          rendered = "openArray[" & element & "]"
        of ntArray:
          if typ.indexTypeSymbol.len > 0:
            let index = knownTypeExpression(typ.indexTypeSymbol, result)
            if index.len > 0:
              rendered = "array[" & index & ", " & element & "]"
          if rendered.len == 0:
            let length = api.arrayLength(typ)
            if length >= 0:
              rendered = "array[" & $length & ", " & element & "]"
        else:
          discard
      else:
        discard
      if rendered.len > 0:
        result[typ.nifSymbol] = rendered
        result[typ.typeId] = rendered
        changed = true

proc nimType(symbol: string, names: Table[string, string]): string =
  if symbol.len == 0:
    return ""
  if symbol in names:
    return names[symbol]
  let builtin = builtinTypeId(symbol)
  if builtin.len > 0:
    return builtin
  let simpleBuiltin = simpleBuiltinType(symbol)
  if simpleBuiltin.len > 0:
    return simpleBuiltin
  let dot = symbol.find('.')
  let name =
    if dot < 0:
      symbol
    else:
      symbol[0 ..< dot]
  case name
  of "bool", "char", "string", "cstring", "pointer", "int", "int8", "int16", "int32",
      "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float", "float32",
      "float64", "cchar", "cschar", "cshort", "cint", "clong", "clonglong", "cuchar",
      "cushort", "cuint", "culong", "culonglong", "cfloat", "cdouble", "csize_t":
    result = name
  else:
    raise
      newException(NativeArtifactError, "unsupported native ABI type symbol: " & symbol)

proc takeMangledName(cursor: var MangledCursor): string =
  let start = cursor.position
  while cursor.position < cursor.value.len and
      cursor.value[cursor.position] in {'0' .. '9'}:
    inc cursor.position
  if cursor.position == start:
    raise newException(
      NativeArtifactError,
      "native ABI symbol has an invalid length-prefixed name: " & cursor.value,
    )
  let length = parseInt(cursor.value[start ..< cursor.position])
  if length <= 0 or cursor.position + length > cursor.value.len:
    raise newException(
      NativeArtifactError,
      "native ABI symbol has an invalid name length: " & cursor.value,
    )
  result = cursor.value[cursor.position ..< cursor.position + length]
  cursor.position += length

proc parseMangledType(cursor: var MangledCursor): MangledType =
  if cursor.position >= cursor.value.len:
    raise newException(
      NativeArtifactError,
      "native ABI symbol ends before its parameter type: " & cursor.value,
    )
  if cursor.value[cursor.position] == 'N':
    inc cursor.position
    while cursor.position < cursor.value.len and cursor.value[cursor.position] != 'E':
      result.name = takeMangledName(cursor)
    if cursor.position >= cursor.value.len:
      raise newException(
        NativeArtifactError,
        "native ABI symbol has an unterminated nested name: " & cursor.value,
      )
    inc cursor.position
  else:
    result.name = takeMangledName(cursor)

  if cursor.position < cursor.value.len and cursor.value[cursor.position] == 'I':
    inc cursor.position
    while cursor.position < cursor.value.len and cursor.value[cursor.position] != 'E':
      result.arguments.add parseMangledType(cursor)
    if cursor.position >= cursor.value.len:
      raise newException(
        NativeArtifactError,
        "native ABI symbol has unterminated type arguments: " & cursor.value,
      )
    inc cursor.position

proc mangledParameterTypes(symbol: string): seq[MangledType] =
  if not symbol.startsWith("_Z"):
    raise newException(
      NativeArtifactError, "native ABI symbol is not a Nim mangled name: " & symbol
    )
  var cursor = MangledCursor(value: symbol, position: 2)
  discard parseMangledType(cursor)
  while cursor.position < cursor.value.len:
    result.add parseMangledType(cursor)

func normalizedMangledName(name: string): string =
  const objectSuffix = "colonObjectType_"
  result = name
  if result.endsWith(objectSuffix):
    result.setLen(result.len - objectSuffix.len)
  case result
  of "uInt":
    result = "uint"
  of "uInt8":
    result = "uint8"
  of "uInt16":
    result = "uint16"
  of "uInt32":
    result = "uint32"
  of "uInt64":
    result = "uint64"
  else:
    discard

proc renderMangledType(typ: MangledType, names: Table[string, string]): string =
  let name = normalizedMangledName(typ.name)
  case name
  of "openArray", "seq", "varargs":
    if typ.arguments.len != 1:
      raise newException(
        NativeArtifactError,
        name & " expects one type argument in the native ABI symbol",
      )
    result = name & "[" & renderMangledType(typ.arguments[0], names) & "]"
  of "tuple":
    if typ.arguments.len < 2:
      raise newException(
        NativeArtifactError,
        "tuple expects at least two type arguments in the native ABI symbol",
      )
    result = "(" & typ.arguments.mapIt(renderMangledType(it, names)).join(", ") & ")"
  of "ref":
    if typ.arguments.len != 1:
      raise newException(
        NativeArtifactError, "ref expects one type argument in the native ABI symbol"
      )
    result = renderMangledType(typ.arguments[0], names)
  of "ptr", "var", "lent":
    if typ.arguments.len != 1:
      raise newException(
        NativeArtifactError,
        name & " expects one type argument in the native ABI symbol",
      )
    result = name & " " & renderMangledType(typ.arguments[0], names)
  else:
    if typ.arguments.len > 0:
      let publicName =
        case name
        of "GVec2": "Vec2"
        of "GVec3": "Vec3"
        of "GVec4": "Vec4"
        of "GMat2": "Mat2"
        of "GMat3": "Mat3"
        of "GMat4": "Mat4"
        else: ""
      if publicName.len > 0 and typ.arguments.len == 1 and
          normalizedMangledName(typ.arguments[0].name) == "float32":
        for generatedName in names.values:
          if generatedName == publicName:
            return generatedName
      raise newException(
        NativeArtifactError,
        "unsupported generic type in native ABI symbol: " & typ.name,
      )
    case name
    of "bool", "char", "string", "cstring", "pointer", "int", "int8", "int16", "int32",
        "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float", "float32",
        "float64":
      result = name
    else:
      for generatedName in names.values:
        if generatedName == name:
          return generatedName
      raise newException(
        NativeArtifactError, "native ABI symbol references an unknown type: " & typ.name
      )

proc generateField(
    field: NativeField, names: Table[string, string], indent: string
): string =
  result.add indent & nimIdentifier(field.name)
  if field.exported:
    result.add "*"
  result.add ": " & nimType(field.typeSymbol, names) & "\n"

proc generateRecord(
    record: seq[NativeRecordPart], names: Table[string, string], indent: string
): string =
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

proc generateTuple(
    record: seq[NativeRecordPart], names: Table[string, string]
): string =
  for part in record:
    if part.kind != nrField:
      raise newException(
        NativeArtifactError, "native ABI tuple cannot contain a case section"
      )
    result.add "    " & nimIdentifier(part.field.name) & ": " &
      nimType(part.field.typeSymbol, names) & "\n"

proc generateTypes(api: NativeApi, names: Table[string, string]): string =
  let types = api.types.filterIt(
      not it.isBuiltinType and not it.imported and
      it.kind notin {ntImportedGeneric, ntOpenArray, ntProc} and
      not it.isAnonymousGenericType
  )
  if types.len == 0:
    return
  result.add "type\n"
  # Case discriminants and their selectors need complete enum declarations,
  # even though other fields can refer forward within the same type section.
  for typ in types.filterIt(it.kind == ntEnum) & types.filterIt(it.kind != ntEnum):
    result.add "  " & nimIdentifier(typ.name) & "*"
    var pragmas: seq[string] = @[]
    if typ.inheritable:
      pragmas.add "inheritable"
    if typ.packed:
      pragmas.add "packed"
    if typ.union:
      pragmas.add "union"
    if pragmas.len > 0:
      result.add " {." & pragmas.join(", ") & ".}"
    result.add " = "
    case typ.kind
    of ntObject:
      result.add "object"
    of ntRefObject:
      result.add "ref object"
    of ntAlias:
      result.add nimType(typ.elementTypeSymbol, names) & "\n\n"
      continue
    of ntDistinct:
      result.add "distinct " & nimType(typ.elementTypeSymbol, names) & "\n\n"
      continue
    of ntArray:
      if typ.indexTypeSymbol.len > 0:
        let index = knownTypeExpression(typ.indexTypeSymbol, names)
        if index.len > 0:
          result.add "array[" & index & ", " & nimType(typ.elementTypeSymbol, names) &
            "]\n\n"
          continue
      let length = api.arrayLength(typ)
      if length < 0:
        raise newException(
          NativeArtifactError, "unsupported native ABI array layout: " & typ.nifSymbol
        )
      result.add "array[" & $length & ", " & nimType(typ.elementTypeSymbol, names) &
        "]\n\n"
      continue
    of ntSequence:
      result.add "seq[" & nimType(typ.elementTypeSymbol, names) & "]\n\n"
      continue
    of ntSet:
      result.add "set[" & nimType(typ.elementTypeSymbol, names) & "]\n\n"
      continue
    of ntTuple:
      result.add "tuple\n"
      result.add generateTuple(typ.record, names)
      result.add "\n"
      continue
    of ntOpenArray:
      raise newException(
        NativeArtifactError, "open arrays are not standalone type declarations"
      )
    of ntProc:
      raise newException(
        NativeArtifactError, "proc types are not standalone type declarations"
      )
    of ntRange:
      raise newException(
        NativeArtifactError, "unsupported named native ABI range: " & typ.name
      )
    of ntImportedGeneric:
      raise newException(
        NativeArtifactError, "imported generic native ABI types are not declarations"
      )
    of ntEnum:
      result.add "enum\n"
      for value in typ.enumValues:
        result.add "    " & nimIdentifier(value.name) & " = " & $value.ordinal & "\n"
      result.add "\n"
      continue
    if typ.baseTypeSymbol.len > 0:
      result.add " of " & nimType(typ.baseTypeSymbol, names)
    result.add "\n"
    result.add generateRecord(typ.record, names, "    ")
    result.add "\n"

proc generateFieldChecks(
    typeName: string,
    record: seq[NativeRecordPart],
    indent: string,
    exportedOnly = false,
): string =
  for part in record:
    case part.kind
    of nrField:
      if part.field.offset >= 0 and (not exportedOnly or part.field.exported):
        result.add indent & "doAssert offsetOf(" & typeName & ", " &
          nimIdentifier(part.field.name) & ") == " & $part.field.offset & "\n"
    of nrCase:
      if part.discriminant.offset >= 0 and
          (not exportedOnly or part.discriminant.exported):
        result.add indent & "doAssert offsetOf(" & typeName & ", " &
          nimIdentifier(part.discriminant.name) & ") == " & $part.discriminant.offset &
          "\n"
      for branch in part.branches:
        result.add generateFieldChecks(typeName, branch.record, indent, exportedOnly)

proc generateLayoutChecks(api: NativeApi, names: Table[string, string]): string =
  let types = api.types.filterIt(
    not it.isBuiltinType and it.kind notin {ntOpenArray, ntProc}
  )
  if types.len == 0:
    return
  result.add "static:\n"
  for typ in types:
    let typeName =
      if typ.isAnonymousGenericType:
        nimType(typ.typeId, names)
      elif typ.kind == ntImportedGeneric:
        nimType(typ.typeId, names)
      else:
        nimIdentifier(typ.name)
    if typ.size >= 0:
      result.add "  doAssert sizeof(" & typeName & ") == " & $typ.size & "\n"
    if typ.alignment >= 0:
      result.add "  doAssert alignof(" & typeName & ") == " & $typ.alignment & "\n"
    if typ.kind == ntObject:
      result.add generateFieldChecks(typeName, typ.record, "  ", typ.imported)
  result.add "\n"

proc params(procInfo: NativeProc, names: Table[string, string]): string =
  var parts: seq[string] = @[]
  let hasHiddenLengths = procInfo.params.anyIt(it.hiddenLengthCount > 0)
  var mangledTypes: seq[MangledType]
  let needsMangledTypes =
    hasHiddenLengths and
    procInfo.params.anyIt(
      it.hiddenLengthCount > 0 and
        (it.typeSymbol notin names or not names[it.typeSymbol].startsWith("openArray["))
    )
  if needsMangledTypes:
    mangledTypes = mangledParameterTypes(procInfo.cSymbol)
    if mangledTypes.len != procInfo.params.len:
      raise newException(
        NativeArtifactError,
        "native ABI symbol parameter count does not match its resolved signature: " &
          procInfo.cSymbol,
      )
  for index, param in procInfo.params:
    if param.hiddenLengthCount > 0:
      if param.hiddenLengthCount != 1:
        raise newException(
          NativeArtifactError,
          "native ABI parameter has an unsupported hidden length count: " & param.name,
        )
      let semanticType =
        if param.typeSymbol in names:
          names[param.typeSymbol]
        else:
          ""
      let logicalType =
        if semanticType.startsWith("openArray[") or semanticType.startsWith("varargs["):
          semanticType
        else:
          renderMangledType(mangledTypes[index], names)
      if not logicalType.startsWith("openArray[") and
          not logicalType.startsWith("varargs["):
        raise newException(
          NativeArtifactError,
          "native ABI hidden length is not attached to an open array: " & param.name,
        )
      parts.add nimIdentifier(param.name) & ": " & logicalType
    else:
      let modifier = if param.byVar: "var " else: ""
      parts.add nimIdentifier(param.name) & ": " & modifier &
        nimType(param.typeSymbol, names)
  result = parts.join("; ")

proc generateNativeModule*(
    api: NativeApi, libraryOverride = "", libraryNameStrdefine = false
): string =
  let
    names = typeNames(api)
    libraryName = if libraryOverride.len > 0: libraryOverride else: api.libraryName
  if libraryName.len == 0:
    raise newException(NativeArtifactError, "native library loader name is empty")
  result.add "# Generated by nim_native_dynlib; do not edit.\n\n"
  var
    imports: seq[string]
    exportedTypes: seq[string]
  for typ in api.types:
    if typ.importModule.len == 0:
      continue
    if typ.importModule notin imports:
      imports.add typ.importModule
    if typ.imported and typ.exported:
      let moduleName = nimIdentifier(typ.importModule.rsplit('/', 1)[^1])
      let exportedType = moduleName & "." & nimIdentifier(typ.name)
      if exportedType notin exportedTypes:
        exportedTypes.add exportedType
  if imports.len > 0:
    result.add "import " & imports.join(", ") & "\n\n"
    for exportedType in exportedTypes:
      result.add "export " & exportedType & "\n"
    if exportedTypes.len > 0:
      result.add "\n"
  result.add "const nativeLibrary*"
  if libraryNameStrdefine:
    result.add " {.strdefine.}"
  result.add " = " & libraryName.escape & "\n\n"
  result.add generateTypes(api, names)
  result.add generateLayoutChecks(api, names)
  result.add "proc nativeNimMain() {.cdecl, importc: " & api.initSymbol.escape &
    ", dynlib: nativeLibrary.}\n\n"
  result.add "nativeNimMain()\n"
  result.add "\n{.push nimcall, dynlib: nativeLibrary.}\n"

  for hook in api.hooks:
    let procInfo = hook.procInfo
    let returnType = nimType(procInfo.returnTypeSymbol, names)
    let returnDecl =
      if returnType.len == 0:
        ""
      else:
        ": " & (if procInfo.returnByVar: "var " else: "") & returnType
    let formals = params(procInfo, names)
    if hook.status == nhCustom:
      result.add "\nproc " & nimIdentifier(hook.kind) & "(" & formals & ")" & returnDecl &
        " {.importc: " & procInfo.cSymbol.escape & ".}\n"
    else:
      result.add "\nproc " & nimIdentifier(hook.kind) & "(" & formals & ")" & returnDecl &
        " {.error.}\n"

  for procInfo in api.procs:
    let returnType = nimType(procInfo.returnTypeSymbol, names)
    let returnDecl =
      if returnType.len == 0:
        ""
      else:
        ": " & (if procInfo.returnByVar: "var " else: "") & returnType
    let formals = params(procInfo, names)
    result.add "\nproc " & nimIdentifier(procInfo.name) & "*(" & formals & ")" &
      returnDecl
    result.add " {.importc: " & procInfo.cSymbol.escape
    if procInfo.discardable:
      result.add ", discardable"
    result.add ".}\n"
  result.add "\n{.pop.}\n"
