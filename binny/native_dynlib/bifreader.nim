import std/[algorithm, os, strutils, tables]
import ./nif/[bif, nifcoreparse, nifqueries]
import exportconfig
import model
import staticlib

type
  NativeBifError* = object of ValueError

  AbiProcEntry = object
    nifSymbol: string
    cSymbol: string
    returnTypeSymbol: string
    returnLowering: NativeLoweringMode
    params: seq[NativeParam]

  AbiHookEntry = object
    typeSymbol: string
    kind: string
    nifSymbol: string
    cSymbol: string
    status: NativeHookStatus

  BifModule = object
    identity: string
    name: string

  BifNativeDescription = object
    libraryName: string
    initSymbol: string
    modules: seq[BifModule]
    types: seq[AbiTypeEntry]
    hooks: seq[AbiHookEntry]
    procs: seq[AbiProcEntry]
    applicationModules: seq[string]

  AbiTypeEntry = object
    typeSymbol: string
    kind: string
    size: int64
    alignment: int64
    layoutFingerprint: string
    inheritable: bool
    packed: bool
    union: bool
    baseTypeSymbol: string
    elementTypeSymbol: string
    enumValues: seq[NativeEnumValue]
    record: seq[NativeRecordPart]

  PreferredTypeAlias = object
    nifSymbol: string
    name: string
    kind: string
    elementSymbol: string
    layoutSymbol: string

proc fail(message: string) {.noinline, noreturn.} =
  raise newException(NativeBifError, message)

func symbolBase(symbol: string): string =
  let dot = symbol.find('.')
  if dot < 0:
    symbol
  else:
    symbol[0 ..< dot]

func symbolModule(symbol: string): string =
  let dot = symbol.rfind('.')
  if dot < 0 or dot == symbol.high:
    ""
  else:
    symbol[dot + 1 .. ^1]

func typeOrdinal(symbol: string): int =
  if not symbol.startsWith("`t"):
    return -1
  let separator = symbol.find('.', 2)
  if separator < 0 or separator == 2:
    return -1
  for character in symbol[2 ..< separator]:
    if character notin {'0' .. '9'}:
      return -1
  result = parseInt(symbol[2 ..< separator])

func bifLayoutKind(symbol: string): string =
  # The number after ``t`` is Nim's ``TTypeKind`` ordinal in semantic BIF.
  case symbol.typeOrdinal
  of 1: "bool"
  of 2: "char"
  of 9: "genericinvocation"
  of 10: "genericbody"
  of 11: "genericinstance"
  of 13: "distinct"
  of 14: "enum"
  of 16: "array"
  of 17: "object"
  of 18: "tuple"
  of 19: "set"
  of 20: "range"
  of 21: "pointer"
  of 22: "ref"
  of 23: "var"
  of 24: "sequence"
  of 26: "pointer"
  of 27: "openarray"
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

func fieldName(symbol: string): string =
  result = symbolBase(symbol)
  let suffix = result.find("`f")
  if suffix >= 0:
    result.setLen(suffix)

proc bifField(node: Cursor): NativeField =
  var children = node.childCursor()
  if children.hasMore and children.kind == SymbolDef:
    result.name = children.symName.fieldName
    children.skip

  var sawMarker = false
  var sawFlags = false
  var integerIndex = 0
  while children.hasMore:
    case children.kind
    of TagLit:
      if children.tagName == "field":
        sawMarker = true
      elif children.tagName == "td" and result.typeSymbol.len == 0:
        let typeId = children.findChildKind(SymbolDef)
        if not typeId.cursorIsNil:
          result.typeSymbol = typeId.symName
    of Ident, Symbol:
      let value = if children.kind == Ident: children.strVal else: children.symName
      if sawMarker and not sawFlags:
        sawFlags = true
        result.exported = 'e' in value
        result.discriminant = 'd' in value
      elif sawMarker and result.typeSymbol.len == 0 and value.startsWith("`t"):
        result.typeSymbol = value
    of IntLit:
      if sawFlags:
        if integerIndex == 0:
          result.offset = children.intVal
        inc integerIndex
    else:
      discard
    children.skip
  result.size = -1
  result.alignment = -1

proc bifRecord(node: Cursor): seq[NativeRecordPart]

proc bifBranch(node: Cursor): NativeBranch =
  result.index = -1
  result.isElse = node.tagName == "else"
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == TagLit:
      case children.tagName
      of "intlit":
        var selector = children.childCursor()
        while selector.hasMore:
          if selector.kind == IntLit:
            result.selectors.add $selector.intVal
            break
          selector.skip
      of "reclist":
        result.record = bifRecord(children)
      else:
        discard
    children.skip

proc bifRecord(node: Cursor): seq[NativeRecordPart] =
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == TagLit:
      case children.tagName
      of "sd":
        if not children.findChildTag("field").cursorIsNil:
          result.add NativeRecordPart(kind: nrField, field: bifField(children))
      of "reccase":
        var recordCase = NativeRecordPart(kind: nrCase)
        var fields = children.childCursor()
        while fields.hasMore:
          if fields.kind == TagLit:
            if fields.tagName == "sd" and not fields.findChildTag("field").cursorIsNil:
              recordCase.discriminant = bifField(fields)
              recordCase.discriminant.discriminant = true
            elif fields.tagName in ["of", "else"]:
              recordCase.branches.add bifBranch(fields)
          fields.skip
        if recordCase.discriminant.name.len > 0:
          result.add recordCase
      else:
        discard
    children.skip

proc bifEnum(node: Cursor): seq[NativeEnumValue] =
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == TagLit and children.tagName == "sd" and
        not children.findChildTag("enumfield").cursorIsNil:
      var value = NativeEnumValue(ordinal: -1)
      var fields = children.childCursor()
      var sawMarker = false
      var hasOrdinal = false
      var integerIndex = 0
      while fields.hasMore:
        case fields.kind
        of SymbolDef:
          value.name = symbolBase(fields.symName)
        of TagLit:
          if fields.tagName == "enumfield":
            sawMarker = true
        of IntLit:
          if sawMarker:
            if integerIndex == 1:
              value.ordinal = fields.intVal
              hasOrdinal = true
            inc integerIndex
        else:
          discard
        fields.skip
      if value.name.len > 0 and hasOrdinal:
        result.add value
    children.skip

proc bifLayout(node: Cursor): AbiTypeEntry =
  var children = node.childCursor()
  if not children.hasMore or children.kind != SymbolDef:
    return
  result.typeSymbol = children.symName
  result.kind = result.typeSymbol.bifLayoutKind
  result.size = -1
  result.alignment = -1
  children.skip

  if children.hasMore:
    children.skip # definition visibility
  var flags = ""
  if children.hasMore:
    if children.kind in {Ident, Symbol}:
      flags = if children.kind == Ident: children.strVal else: children.symName
    children.skip
  result.inheritable = 'i' in flags
  result.packed = 'p' in flags
  result.union = 'q' in flags
  if children.hasMore:
    children.skip # calling convention
  if children.hasMore and children.kind == IntLit:
    result.size = children.intVal
    children.skip
  if children.hasMore and children.kind == IntLit:
    result.alignment = children.intVal
    children.skip

  var tailTypes: seq[string]
  var nestedLayouts: seq[AbiTypeEntry]
  var sawMetadataString = false
  while children.hasMore:
    case children.kind
    of StrLit:
      sawMetadataString = true
    of Symbol:
      if sawMetadataString and children.symName.startsWith("`t"):
        tailTypes.add children.symName
    of TagLit:
      case children.tagName
      of "reclist":
        result.record = bifRecord(children)
      of "enumty":
        result.enumValues = bifEnum(children)
      of "td":
        let nested = bifLayout(children)
        if nested.typeSymbol.len > 0:
          nestedLayouts.add nested
      else:
        discard
    else:
      discard
    children.skip

  if result.kind == "genericinstance" and nestedLayouts.len > 0:
    let actual = nestedLayouts[^1]
    result.kind = actual.kind
    result.baseTypeSymbol = actual.baseTypeSymbol
    result.elementTypeSymbol = actual.elementTypeSymbol
    result.enumValues = actual.enumValues
    result.record = actual.record
    result.inheritable = actual.inheritable
    result.packed = actual.packed
    result.union = actual.union
    if result.size < 0:
      result.size = actual.size
    if result.alignment < 0:
      result.alignment = actual.alignment
  elif result.kind == "ref" and nestedLayouts.len > 0:
    result.elementTypeSymbol = nestedLayouts[^1].typeSymbol
  elif result.kind in [
    "array", "distinct", "genericbody", "genericinvocation", "openarray", "range",
    "sequence", "set", "string", "var",
  ]:
    if tailTypes.len > 0:
      result.elementTypeSymbol = tailTypes[^1]
    elif nestedLayouts.len > 0:
      result.elementTypeSymbol = nestedLayouts[^1].typeSymbol
  elif result.kind == "object" and tailTypes.len > 0:
    result.baseTypeSymbol = tailTypes[^1]
  elif result.kind == "tuple" and result.record.len == 0:
    for index, typeSymbol in tailTypes:
      result.record.add NativeRecordPart(
        kind: nrField,
        field: NativeField(
          name: "Field" & $index,
          typeSymbol: typeSymbol,
          offset: -1,
          size: -1,
          alignment: -1,
        ),
      )

proc mergeLayout(layouts: var Table[string, AbiTypeEntry], layout: AbiTypeEntry) =
  if layout.typeSymbol.len == 0 or layout.kind.len == 0:
    return
  if layout.typeSymbol notin layouts:
    layouts[layout.typeSymbol] = layout
    return
  var merged = layouts[layout.typeSymbol]
  if merged.kind in ["genericinstance", "genericinvocation", "genericbody"] and
      layout.kind in
      ["object", "enum", "distinct", "array", "sequence", "set", "tuple", "openarray"]:
    merged.kind = layout.kind
  if merged.size < 0 and layout.size >= 0:
    merged.size = layout.size
  if merged.alignment < 0 and layout.alignment >= 0:
    merged.alignment = layout.alignment
  if merged.record.len == 0 and layout.record.len > 0:
    merged.record = layout.record
  if merged.enumValues.len == 0 and layout.enumValues.len > 0:
    merged.enumValues = layout.enumValues
  if merged.baseTypeSymbol.len == 0:
    merged.baseTypeSymbol = layout.baseTypeSymbol
  if merged.elementTypeSymbol.len == 0:
    merged.elementTypeSymbol = layout.elementTypeSymbol
  merged.inheritable = merged.inheritable or layout.inheritable
  merged.packed = merged.packed or layout.packed
  merged.union = merged.union or layout.union
  layouts[layout.typeSymbol] = merged

proc collectBifLayouts(node: Cursor, layouts: var Table[string, AbiTypeEntry]) =
  if node.kind != TagLit:
    return
  if node.tagName == "td":
    layouts.mergeLayout(bifLayout(node))
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == TagLit:
      collectBifLayouts(children, layouts)
    children.skip

proc resolveRecordSelectors(
    record: var seq[NativeRecordPart], layouts: Table[string, AbiTypeEntry]
) =
  for part in record.mitems:
    if part.kind == nrCase:
      let enumSymbol = part.discriminant.typeSymbol
      for branch in part.branches.mitems:
        if enumSymbol in layouts:
          for selector in branch.selectors.mitems:
            let ordinal = parseInt(selector)
            for value in layouts[enumSymbol].enumValues:
              if value.ordinal == ordinal:
                selector = value.name
                break
        resolveRecordSelectors(branch.record, layouts)

proc finalizeLayouts(layouts: var Table[string, AbiTypeEntry]) =
  for layout in layouts.mvalues:
    resolveRecordSelectors(layout.record, layouts)
    for part in layout.record.mitems:
      if part.kind == nrField and part.field.typeSymbol in layouts:
        let fieldType = layouts[part.field.typeSymbol]
        part.field.size = fieldType.size
        part.field.alignment = fieldType.alignment

proc hasDescendantIdent(node: Cursor, name: string): bool =
  if node.kind != TagLit:
    return false
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == Ident and children.strVal == name:
      return true
    if children.kind == TagLit and children.hasDescendantIdent(name):
      return true
    children.skip

proc parseNativeType(
    declaration: Cursor, nifSymbol: string, typ: var NativeType
): bool =
  typ.size = -1
  typ.alignment = -1
  let sourceType = declaration.findChildTag("type0")
  if sourceType.cursorIsNil:
    return false

  let refType = sourceType.findChildTag("refty")
  let objectType = sourceType.findChildTag("objectty")
  let enumType = sourceType.findChildTag("enumty")
  let distinctType = sourceType.findChildTag("distinctty")
  let arrayType = sourceType.findChildTag("arrayty")
  let aliasType = sourceType.findChildTag("ht")
  let instanceType = sourceType.findChildTag("at")
  let typeDesc = declaration.findChildTag("td")
  if not typeDesc.cursorIsNil:
    let declaredLayout = bifLayout(typeDesc)
    typ.size = declaredLayout.size
    typ.alignment = declaredLayout.alignment
  let rangeType =
    if typeDesc.cursorIsNil:
      default(Cursor)
    else:
      typeDesc.findChildTag("range")
  typ.name = symbolBase(nifSymbol)
  typ.nifSymbol = nifSymbol
  for typeNode in [refType, objectType, enumType, distinctType, arrayType]:
    if not typeNode.cursorIsNil:
      let typeId = typeNode.findChildKind(Symbol)
      if not typeId.cursorIsNil:
        typ.typeId = typeId.symName
        break
  if typ.typeId.len == 0 or not rangeType.cursorIsNil:
    if not typeDesc.cursorIsNil:
      let typeId = typeDesc.findChildKind(SymbolDef)
      if not typeId.cursorIsNil:
        typ.typeId = typeId.symName
  if typ.typeId.len == 0:
    return false
  if not refType.cursorIsNil:
    let payload = refType.findChildTag("objectty")
    if payload.cursorIsNil:
      return false
    typ.kind = ntRefObject
  elif not objectType.cursorIsNil:
    typ.kind = ntObject
  elif not enumType.cursorIsNil:
    typ.kind = ntEnum
  elif not distinctType.cursorIsNil:
    typ.kind = ntDistinct
  elif not arrayType.cursorIsNil:
    typ.kind = ntArray
  elif not rangeType.cursorIsNil:
    typ.kind = ntRange
  elif not aliasType.cursorIsNil:
    let elementType = aliasType.findLastChildKind(Symbol)
    if elementType.cursorIsNil:
      return false
    typ.kind = ntAlias
    typ.elementTypeSymbol = elementType.symName
  elif not instanceType.cursorIsNil:
    typ.kind = ntAlias
    typ.elementTypeSymbol = typ.typeId
    let indexTypeNode = instanceType.findChildTag("ht")
    if not indexTypeNode.cursorIsNil:
      let indexType = indexTypeNode.findLastChildKind(Symbol)
      if not indexType.cursorIsNil:
        typ.indexTypeSymbol = indexType.symName
  else:
    return false
  result = true

proc parsePreferredTypeAlias(
    declaration: Cursor, nifSymbol: string
): PreferredTypeAlias =
  let sourceType = declaration.findChildTag("type0")
  if sourceType.cursorIsNil:
    return
  let instanceType = sourceType.findChildTag("at")
  if instanceType.cursorIsNil:
    return

  var symbols: seq[string]
  var children = instanceType.childCursor()
  while children.hasMore:
    if children.kind == Symbol:
      symbols.add children.symName
    elif children.kind notin {DotToken, TagLit}:
      return
    children.skip
  if symbols.len < 2:
    return

  case symbolBase(symbols[1])
  of "seq":
    if symbols.len != 3:
      return
    result.kind = "sequence"
  of "set":
    if symbols.len != 3:
      return
    result.kind = "set"
  else:
    result.layoutSymbol = symbols[0]
  result.nifSymbol = nifSymbol
  result.name = symbolBase(nifSymbol)
  if result.kind.len > 0:
    result.elementSymbol = symbols[2]

proc parseParam(declaration: Cursor): NativeParam =
  let name = declaration.findChildKind(SymbolDef)
  if not name.cursorIsNil:
    result.name = symbolBase(name.symName)
  let metadata = declaration.findChildTag("param")
  if metadata.cursorIsNil:
    fail("missing parameter metadata for " & result.name)
  let typeDesc = declaration.findChildTag("td")
  if not typeDesc.cursorIsNil:
    let typeIdNode = typeDesc.findChildKind(SymbolDef)
    let typeId = if typeIdNode.cursorIsNil: "" else: typeIdNode.symName
    if typeId.startsWith("`t23."):
      result.byVar = true
      let typeSymbol = typeDesc.findLastChildKind(Symbol)
      if not typeSymbol.cursorIsNil:
        result.typeSymbol = typeSymbol.symName
    else:
      result.typeSymbol = typeId
  else:
    let typeSymbol = declaration.findChildKind(Symbol)
    if not typeSymbol.cursorIsNil:
      result.typeSymbol = typeSymbol.symName
  if result.typeSymbol.len == 0:
    fail("native ABI only supports value parameters: " & result.name)

proc parseParamPosition(declaration: Cursor): int =
  var
    children = declaration.childCursor()
    sawParamMetadata = false
    integerIndex = 0
  while children.hasMore:
    if children.kind == TagLit and children.tagName == "param":
      sawParamMetadata = true
    elif sawParamMetadata and children.kind == IntLit:
      if integerIndex == 1:
        return int(children.intVal)
      inc integerIndex
    children.skip
  fail("missing parameter position metadata")

proc parseNativeProc(declaration: Cursor, abi: AbiProcEntry): NativeProc =
  result.name = symbolBase(abi.nifSymbol)
  result.nifSymbol = abi.nifSymbol
  result.cSymbol = abi.cSymbol
  result.returnLowering = abi.returnLowering
  result.callConv = "nimcall"
  result.discardable = declaration.hasDescendantIdent("discardable")
  let formals = declaration.findDescendantTag("formalparams")
  if formals.cursorIsNil:
    fail("missing resolved signature for " & abi.nifSymbol)

  var children = formals.childCursor()
  if children.hasMore:
    children.skip # expression flags
  if children.hasMore:
    if children.kind == Symbol:
      result.returnTypeSymbol = children.symName
      result.returnByVar = result.returnTypeSymbol.startsWith("`t23.")
    children.skip
  type IndexedParam = tuple[position: int, param: NativeParam]

  proc collectParams(node: Cursor, params: var seq[IndexedParam]) =
    var nested = node.childCursor()
    while nested.hasMore:
      if nested.kind == TagLit:
        if nested.tagName == "sd" and not nested.findChildTag("param").cursorIsNil:
          var belongsToProc = false
          var fields = nested.childCursor()
          while fields.hasMore:
            if fields.kind == Symbol and fields.symName == abi.nifSymbol:
              belongsToProc = true
              break
            fields.skip
          if belongsToProc:
            params.add (nested.parseParamPosition, nested.parseParam)
        else:
          collectParams(nested, params)
      nested.skip

  var params: seq[IndexedParam]
  collectParams(formals, params)
  params.sort(
    proc(left, right: IndexedParam): int =
      cmp(left.position, right.position)
  )
  for item in params:
    result.params.add item.param

proc unwrapVarReturn(procInfo: var NativeProc, layouts: Table[string, AbiTypeEntry]) =
  if not procInfo.returnByVar:
    return
  if procInfo.returnTypeSymbol notin layouts:
    fail("native ABI var return type has no layout: " & procInfo.returnTypeSymbol)
  let wrapper = layouts[procInfo.returnTypeSymbol]
  if wrapper.kind != "var" or wrapper.elementTypeSymbol.len == 0:
    fail(
      "native ABI var return type has an invalid layout: " & procInfo.returnTypeSymbol
    )
  procInfo.returnTypeSymbol = wrapper.elementTypeSymbol

proc applyLayout(typ: var NativeType, layouts: Table[string, AbiTypeEntry]): bool =
  if typ.typeId notin layouts:
    return false
  let declared = layouts[typ.typeId]
  if typ.kind == ntAlias and typ.elementTypeSymbol == typ.typeId:
    case declared.kind
    of "object":
      typ.kind = ntObject
    of "enum":
      typ.kind = ntEnum
    of "distinct":
      typ.kind = ntDistinct
    of "array":
      typ.kind = ntArray
    of "sequence":
      typ.kind = ntSequence
    of "set":
      typ.kind = ntSet
    of "tuple":
      typ.kind = ntTuple
    else:
      return false
  typ.size = declared.size
  typ.alignment = declared.alignment
  typ.layoutFingerprint = declared.layoutFingerprint
  typ.inheritable = declared.inheritable
  typ.packed = declared.packed
  typ.union = declared.union
  typ.enumValues = declared.enumValues

  var recordLayout = declared
  if typ.kind == ntRefObject and recordLayout.record.len == 0 and
      recordLayout.elementTypeSymbol in layouts:
    recordLayout = layouts[recordLayout.elementTypeSymbol]
  typ.baseTypeSymbol = recordLayout.baseTypeSymbol
  if typ.kind != ntAlias:
    typ.elementTypeSymbol = declared.elementTypeSymbol
  typ.record = recordLayout.record
  result = true

proc typeFromLayout(layout: AbiTypeEntry): NativeType =
  result.name =
    "NativeAbi" & layout.typeSymbol.multiReplace(("`", ""), (".", "_"), ("-", "_"))
  result.nifSymbol = layout.typeSymbol
  result.typeId = layout.typeSymbol
  result.baseTypeSymbol = layout.baseTypeSymbol
  result.elementTypeSymbol = layout.elementTypeSymbol
  result.size = layout.size
  result.alignment = layout.alignment
  result.layoutFingerprint = layout.layoutFingerprint
  result.inheritable = layout.inheritable
  result.packed = layout.packed
  result.union = layout.union
  result.enumValues = layout.enumValues
  result.record = layout.record
  case layout.kind
  of "object":
    result.kind = ntObject
  of "enum":
    result.kind = ntEnum
  of "distinct":
    result.kind = ntDistinct
  of "array":
    result.kind = ntArray
  of "sequence":
    result.kind = ntSequence
  of "set":
    result.kind = ntSet
  of "tuple":
    result.kind = ntTuple
  of "openarray":
    result.kind = ntOpenArray
  else:
    fail("unsupported native ABI layout kind: " & layout.kind)

proc parseStdOrderedTable(
    node: Cursor,
    stdTablesModules: Table[string, bool],
    layouts: Table[string, AbiTypeEntry],
    typ: var NativeType,
): bool =
  if node.kind != TagLit or node.tagName != "at":
    return false

  var symbols: seq[string]
  var arguments: seq[string]
  var children = node.childCursor()
  while children.hasMore:
    case children.kind
    of Symbol:
      symbols.add children.symName
    of TagLit:
      if children.tagName != "ht":
        return false
      let argument = children.findLastChildKind(Symbol)
      if argument.cursorIsNil:
        return false
      arguments.add argument.symName
    of DotToken:
      discard
    else:
      return false
    children.skip

  if symbols.len != 2 or arguments.len != 2 or symbolBase(symbols[1]) != "OrderedTable" or
      symbolModule(symbols[1]) notin stdTablesModules or symbols[0] notin layouts or
      layouts[symbols[0]].kind != "object":
    return false

  let layout = layouts[symbols[0]]
  typ = NativeType(
    name: "OrderedTable",
    nifSymbol: layout.typeSymbol,
    typeId: layout.typeSymbol,
    kind: ntImportedGeneric,
    size: layout.size,
    alignment: layout.alignment,
    layoutFingerprint: layout.layoutFingerprint,
    importModule: "std/tables",
    genericArguments: arguments,
  )
  result = true

proc collectStdOrderedTables(
    node: Cursor,
    stdTablesModules: Table[string, bool],
    layouts: Table[string, AbiTypeEntry],
    instances: var Table[string, NativeType],
    skipTypes: var Table[string, bool],
) =
  if node.kind != TagLit:
    return
  var typ: NativeType
  if parseStdOrderedTable(node, stdTablesModules, layouts, typ):
    instances[typ.typeId] = typ
    skipTypes[typ.nifSymbol] = true
    skipTypes[typ.typeId] = true
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == TagLit:
      collectStdOrderedTables(children, stdTablesModules, layouts, instances, skipTypes)
    children.skip

func isMaterializedKind(kind: string): bool =
  kind in
    ["object", "enum", "distinct", "array", "sequence", "set", "tuple", "openarray"]

proc addLayoutDependency(
  layoutSymbol: string,
  layouts: Table[string, AbiTypeEntry],
  dependencies: var Table[string, bool],
)

proc collectLayoutDependencies(
  layout: AbiTypeEntry,
  layouts: Table[string, AbiTypeEntry],
  dependencies: var Table[string, bool],
)

proc collectRecordDependencies(
  record: seq[NativeRecordPart],
  layouts: Table[string, AbiTypeEntry],
  dependencies: var Table[string, bool],
)

proc collectBranchDependencies(
    branches: seq[NativeBranch],
    layouts: Table[string, AbiTypeEntry],
    dependencies: var Table[string, bool],
) =
  for branch in branches:
    collectRecordDependencies(branch.record, layouts, dependencies)

proc collectRecordDependencies(
    record: seq[NativeRecordPart],
    layouts: Table[string, AbiTypeEntry],
    dependencies: var Table[string, bool],
) =
  for part in record:
    case part.kind
    of nrField:
      addLayoutDependency(part.field.typeSymbol, layouts, dependencies)
    of nrCase:
      addLayoutDependency(part.discriminant.typeSymbol, layouts, dependencies)
      collectBranchDependencies(part.branches, layouts, dependencies)

proc collectLayoutDependencies(
    layout: AbiTypeEntry,
    layouts: Table[string, AbiTypeEntry],
    dependencies: var Table[string, bool],
) =
  if layout.typeSymbol.len == 0 or layout.typeSymbol in dependencies:
    return
  dependencies[layout.typeSymbol] = true
  addLayoutDependency(layout.baseTypeSymbol, layouts, dependencies)
  addLayoutDependency(layout.elementTypeSymbol, layouts, dependencies)
  collectRecordDependencies(layout.record, layouts, dependencies)

proc addLayoutDependency(
    layoutSymbol: string,
    layouts: Table[string, AbiTypeEntry],
    dependencies: var Table[string, bool],
) =
  if layoutSymbol.len == 0 or layoutSymbol in dependencies or layoutSymbol notin layouts:
    return
  collectLayoutDependencies(layouts[layoutSymbol], layouts, dependencies)

proc collectReferencedBranchDependencies(
  branches: seq[NativeBranch],
  layouts: Table[string, AbiTypeEntry],
  requiredTypes: var Table[string, bool],
  skipInternal: Table[string, bool],
)

proc collectReferencedRecordDependencies(
  record: seq[NativeRecordPart],
  layouts: Table[string, AbiTypeEntry],
  requiredTypes: var Table[string, bool],
  skipInternal: Table[string, bool],
)

proc collectReferencedLayoutDependencies(
  layout: AbiTypeEntry,
  layouts: Table[string, AbiTypeEntry],
  requiredTypes: var Table[string, bool],
  skipInternal: Table[string, bool],
)

proc shouldSkipReferencedType(
    symbol: string, layouts: Table[string, AbiTypeEntry]
): bool =
  if symbol.len == 0 or symbol notin layouts:
    return false
  let layout = layouts[symbol]
  let usableUnknownLayout =
    layout.kind in ["openarray", "sequence", "set"] or
    layout.kind in ["object", "tuple"] and layout.record.len > 0
  layout.size < 0 and not usableUnknownLayout or
    layout.kind in ["genericbody", "genericinvocation"]

proc collectReferencedType(
    symbol: string,
    layouts: Table[string, AbiTypeEntry],
    requiredTypes: var Table[string, bool],
    skipInternal: Table[string, bool],
) =
  if symbol.len == 0 or symbol in skipInternal:
    return
  if symbol in requiredTypes:
    return
  if symbol notin layouts:
    requiredTypes[symbol] = true
    return
  if shouldSkipReferencedType(symbol, layouts):
    return
  requiredTypes[symbol] = true
  collectReferencedLayoutDependencies(
    layouts[symbol], layouts, requiredTypes, skipInternal
  )

proc collectReferencedBranchDependencies(
    branches: seq[NativeBranch],
    layouts: Table[string, AbiTypeEntry],
    requiredTypes: var Table[string, bool],
    skipInternal: Table[string, bool],
) =
  for branch in branches:
    collectReferencedRecordDependencies(
      branch.record, layouts, requiredTypes, skipInternal
    )

proc collectReferencedRecordDependencies(
    record: seq[NativeRecordPart],
    layouts: Table[string, AbiTypeEntry],
    requiredTypes: var Table[string, bool],
    skipInternal: Table[string, bool],
) =
  for part in record:
    case part.kind
    of nrField:
      collectReferencedType(part.field.typeSymbol, layouts, requiredTypes, skipInternal)
    of nrCase:
      collectReferencedType(
        part.discriminant.typeSymbol, layouts, requiredTypes, skipInternal
      )
      collectReferencedBranchDependencies(
        part.branches, layouts, requiredTypes, skipInternal
      )

proc collectReferencedLayoutDependencies(
    layout: AbiTypeEntry,
    layouts: Table[string, AbiTypeEntry],
    requiredTypes: var Table[string, bool],
    skipInternal: Table[string, bool],
) =
  collectReferencedType(layout.baseTypeSymbol, layouts, requiredTypes, skipInternal)
  collectReferencedType(layout.elementTypeSymbol, layouts, requiredTypes, skipInternal)
  collectReferencedRecordDependencies(
    layout.record, layouts, requiredTypes, skipInternal
  )

proc resolvedSemanticTypeSymbol(
    symbol: string,
    semanticTypeSymbols: Table[string, string],
    layouts: Table[string, AbiTypeEntry],
): string =
  if symbol in semanticTypeSymbols:
    return semanticTypeSymbols[symbol]
  let typeName = symbolBase(symbol)
  let moduleId = symbolModule(symbol)
  for layout in layouts.values:
    if layout.kind == typeName and symbolModule(layout.typeSymbol) == moduleId:
      return layout.typeSymbol
  symbol

proc collectPreferredLayoutNames(
    aliases: openArray[PreferredTypeAlias],
    semanticTypeSymbols: Table[string, string],
    layouts: Table[string, AbiTypeEntry],
    requiredTypes: Table[string, bool],
): Table[string, string] =
  var ambiguous: Table[string, bool]
  for alias in aliases:
    if alias.layoutSymbol in requiredTypes and alias.layoutSymbol in layouts and
        alias.layoutSymbol notin ambiguous:
      if alias.layoutSymbol notin result:
        result[alias.layoutSymbol] = alias.name
      elif result[alias.layoutSymbol] != alias.name:
        result.del alias.layoutSymbol
        ambiguous[alias.layoutSymbol] = true
  for alias in aliases:
    if alias.kind.len > 0:
      let elementSymbol =
        resolvedSemanticTypeSymbol(alias.elementSymbol, semanticTypeSymbols, layouts)
      for layout in layouts.values:
        if layout.typeSymbol in requiredTypes and layout.kind == alias.kind and
            layout.elementTypeSymbol == elementSymbol and
            layout.typeSymbol notin ambiguous:
          if layout.typeSymbol notin result:
            result[layout.typeSymbol] = alias.name
          elif result[layout.typeSymbol] != alias.name:
            result.del layout.typeSymbol
            ambiguous[layout.typeSymbol] = true

proc addAbiModule(
    modules: var seq[bif.BifModule], seenPaths: var Table[string, bool], path: string
) =
  let normalized = normalizedPath(absolutePath(path))
  if normalized notin seenPaths:
    if not fileExists(normalized):
      fail("semantic BIF not found: " & normalized)
    seenPaths[normalized] = true
    modules.add bif.load(normalized)

proc loadBifModules(
    bifPath: string, description: BifNativeDescription
): seq[bif.BifModule] =
  let nimcacheDir = bifPath.parentDir
  var seenPaths: Table[string, bool]
  addAbiModule(result, seenPaths, bifPath)
  for module in description.modules:
    addAbiModule(result, seenPaths, nimcacheDir / (module.identity & ".s.bif"))

proc findSemanticDeclaration(modules: var seq[bif.BifModule], symbol: string): Cursor =
  for module in modules.mitems:
    let declaration = bif.findDeclaration(module, symbol)
    if not declaration.cursorIsNil:
      return declaration

proc readModuleSource*(path: string): string

func isStdTablesSource(path: string): bool =
  let normalized = normalizedPath(path).replace('\\', '/')
  normalized.endsWith("/lib/pure/collections/tables.nim") or
    normalized.endsWith("/lib/std/tables.nim")

proc normalizedAbsolutePath(path: string): string =
  if fileExists(path) or dirExists(path):
    result = expandFilename(path)
  else:
    result = absolutePath(path)
  normalizePath(result)

proc pathIsWithin(path, root: string): bool =
  let relative = relativePath(path, root)
  result = relative != ".." and not relative.startsWith(".." & $DirSep)

func bifIdentity(path: string): string =
  const suffix = ".s.bif"
  let name = path.extractFilename
  if name.endsWith(suffix):
    result = name[0 ..< name.len - suffix.len]

proc bifNativeDescription(
    nimcacheDir, sourceRoot, libraryName, initSymbol: string,
    routines: openArray[NativeExportSymbol],
    hooks: openArray[NativeHookSymbol],
): BifNativeDescription =
  result.libraryName = libraryName
  result.initSymbol = initSymbol

  let root = sourceRoot.normalizedAbsolutePath
  var paths: seq[string]
  for path in walkFiles(nimcacheDir / "*.s.bif"):
    paths.add path
  paths.sort()

  var layouts: Table[string, AbiTypeEntry]
  for path in paths:
    let source = readModuleSource(path)
    if source.len == 0:
      continue
    let identity = path.bifIdentity
    result.modules.add BifModule(identity: identity, name: source.splitFile.name)
    if source.normalizedAbsolutePath.pathIsWithin(root):
      result.applicationModules.add identity

    var module = bif.load(path)
    for _, _, declaration in module.declarations:
      collectBifLayouts(declaration, layouts)

  finalizeLayouts(layouts)
  for layout in layouts.values:
    result.types.add layout
  result.types.sort(
    proc(left, right: AbiTypeEntry): int =
      cmp(left.typeSymbol, right.typeSymbol)
  )

  for symbol in routines:
    result.procs.add AbiProcEntry(nifSymbol: symbol.nifSymbol, cSymbol: symbol.cSymbol)
  for hook in hooks:
    result.hooks.add AbiHookEntry(
      typeSymbol: hook.typeSymbol,
      kind: hook.hookKind,
      nifSymbol: hook.nifSymbol,
      cSymbol: hook.cSymbol,
      status: if hook.forbidden: nhForbidden else: nhCustom,
    )

proc buildNativeApi(
    bifPath: string, sourceDescription: BifNativeDescription
): NativeApi =
  var description = sourceDescription
  result.libraryName = description.libraryName
  result.initSymbol = description.initSymbol

  var layouts: Table[string, AbiTypeEntry]
  var preferredTypeIndexes: Table[string, int]
  for layout in description.types:
    layouts[layout.typeSymbol] = layout

  var modules = loadBifModules(bifPath, description)
  for item in description.procs.mitems:
    let declaration = findSemanticDeclaration(modules, item.nifSymbol)
    if declaration.cursorIsNil:
      fail("semantic declaration not found for " & item.nifSymbol)
    let semantic = parseNativeProc(declaration, item)
    item.returnTypeSymbol = semantic.returnTypeSymbol
    item.params = semantic.params
    item.returnLowering = if semantic.returnTypeSymbol.len == 0: nlVoid else: nlDirect
    for param in item.params.mitems:
      if param.typeSymbol in layouts and layouts[param.typeSymbol].kind == "openarray":
        param.lowering = nlPointer
        param.hiddenLengthCount = 1
      elif param.byVar:
        param.lowering = nlPointer
      else:
        param.lowering = nlDirect
  var skipSystemModuleTypeSymbols: Table[string, bool]
  var stdTablesModules: Table[string, bool]
  var signatureTypeSymbols: Table[string, bool]
  for item in description.procs:
    if item.returnTypeSymbol.len > 0:
      signatureTypeSymbols[item.returnTypeSymbol] = true
    for param in item.params:
      signatureTypeSymbols[param.typeSymbol] = true
  for module in description.modules:
    if module.name == "system":
      skipSystemModuleTypeSymbols[module.identity] = true
    if module.name == "tables":
      let path = bifPath.parentDir / (module.identity & ".s.bif")
      if readModuleSource(path).isStdTablesSource:
        stdTablesModules[module.identity] = true

  var importedGenericTypes: Table[string, NativeType]
  var skipStdTableObjectTypes: Table[string, bool]
  var unmaterializedTypes: seq[NativeType]
  var preferredTypeAliases: seq[PreferredTypeAlias]
  var applicationModules: Table[string, bool]
  var seenSemanticTypes: Table[string, bool]
  for identity in description.applicationModules:
    applicationModules[identity] = true
  for moduleIndex, module in modules.mpairs:
    for nifSymbol, visibility, declaration in module.declarations:
      let moduleId = symbolModule(nifSymbol)
      let inspectDeclaration = visibility == ivExported
      if inspectDeclaration:
        if not declaration.findChildTag("type").cursorIsNil and
            not declaration.findChildTag("type0").cursorIsNil:
          collectStdOrderedTables(
            declaration, stdTablesModules, layouts, importedGenericTypes,
            skipStdTableObjectTypes,
          )
          var typ: NativeType
          if parseNativeType(declaration, nifSymbol, typ):
            let typeKey = typ.nifSymbol & "\x1f" & typ.typeId
            if typeKey in seenSemanticTypes:
              continue
            seenSemanticTypes[typeKey] = true
            let hasLayout = applyLayout(typ, layouts)
            if typ.kind != ntAlias and not hasLayout:
              typ.size = -1
              typ.alignment = -1
              unmaterializedTypes.add typ
              continue
            if symbolModule(typ.nifSymbol) in stdTablesModules and
                symbolBase(typ.nifSymbol) == "OrderedTable":
              continue
            if typ.nifSymbol in skipStdTableObjectTypes or
                typ.typeId in skipStdTableObjectTypes:
              continue
            result.types.add typ
            # Only root aliases should name equivalent layouts from dependencies.
            if moduleIndex == 0 and visibility == ivExported:
              let alias = parsePreferredTypeAlias(declaration, nifSymbol)
              if alias.name.len > 0:
                preferredTypeAliases.add alias
                preferredTypeIndexes[alias.name] = result.types.high

  for typ in importedGenericTypes.values:
    result.types.add typ

  for alias in preferredTypeAliases:
    if alias.layoutSymbol notin layouts:
      continue
    for typ in result.types:
      if typ.nifSymbol == alias.nifSymbol:
        var offered = layouts[alias.layoutSymbol]
        if offered.size < 0 and typ.size >= 0:
          offered.size = typ.size
        if offered.alignment < 0 and typ.alignment >= 0:
          offered.alignment = typ.alignment
        layouts[alias.layoutSymbol] = offered
        break

  var represented: Table[string, bool]
  for typ in result.types:
    represented[typ.typeId] = true

  var internalLayoutTypes: Table[string, bool]
  for typ in importedGenericTypes.values:
    addLayoutDependency(typ.typeId, layouts, internalLayoutTypes)
  for typ in importedGenericTypes.values:
    internalLayoutTypes.del typ.typeId

  for item in description.procs:
    let nifSymbol = item.nifSymbol
    let declaration = findSemanticDeclaration(modules, nifSymbol)
    if declaration.cursorIsNil:
      fail("semantic declaration not found for " & nifSymbol)
    result.procs.add parseNativeProc(declaration, item)

  for item in description.hooks:
    let declaration = findSemanticDeclaration(modules, item.nifSymbol)
    if declaration.cursorIsNil:
      fail("semantic hook declaration not found for " & item.nifSymbol)
    result.hooks.add NativeHook(
      typeSymbol: item.typeSymbol,
      kind: item.kind,
      status: item.status,
      procInfo: parseNativeProc(
        declaration,
        AbiProcEntry(
          nifSymbol: item.nifSymbol, cSymbol: item.cSymbol, returnLowering: nlDirect
        ),
      ),
    )

  for procInfo in result.procs.mitems:
    unwrapVarReturn(procInfo, layouts)
  for hook in result.hooks.mitems:
    unwrapVarReturn(hook.procInfo, layouts)

  var skipInternalTypes = internalLayoutTypes

  var requiredTypes: Table[string, bool]
  for typ in result.types:
    let moduleIdentity = symbolModule(typ.nifSymbol)
    let isSignatureType =
      typ.nifSymbol in signatureTypeSymbols or typ.typeId in signatureTypeSymbols
    let isMaterializedSemanticType =
      typ.kind != ntAlias and moduleIdentity in applicationModules
    if isSignatureType or isMaterializedSemanticType:
      if moduleIdentity.len > 0 and moduleIdentity in skipSystemModuleTypeSymbols:
        continue
      let symbolSkip =
        if typ.kind == ntImportedGeneric:
          skipInternalTypes
        else:
          initTable[string, bool]()
      collectReferencedType(typ.typeId, layouts, requiredTypes, symbolSkip)
      if typ.kind == ntArray:
        collectReferencedType(typ.indexTypeSymbol, layouts, requiredTypes, symbolSkip)
      if typ.kind == ntAlias:
        collectReferencedType(typ.elementTypeSymbol, layouts, requiredTypes, symbolSkip)

  for procInfo in result.procs:
    collectReferencedType(
      procInfo.returnTypeSymbol, layouts, requiredTypes, skipInternalTypes
    )
    for param in procInfo.params:
      collectReferencedType(param.typeSymbol, layouts, requiredTypes, skipInternalTypes)
  for hook in result.hooks:
    collectReferencedType(
      hook.procInfo.returnTypeSymbol, layouts, requiredTypes, skipInternalTypes
    )
    for param in hook.procInfo.params:
      collectReferencedType(param.typeSymbol, layouts, requiredTypes, skipInternalTypes)
  for symbol in signatureTypeSymbols.keys:
    requiredTypes[symbol] = true

  var previousRequiredCount = -1
  while previousRequiredCount != requiredTypes.len:
    previousRequiredCount = requiredTypes.len
    for typ in result.types:
      if typ.kind == ntImportedGeneric and typ.typeId in requiredTypes:
        for argument in typ.genericArguments:
          collectReferencedType(argument, layouts, requiredTypes, skipInternalTypes)

  var semanticTypeSymbols: Table[string, string]
  for typ in result.types:
    if typ.nifSymbol.len > 0 and typ.typeId.len > 0:
      semanticTypeSymbols[typ.nifSymbol] = typ.typeId
  for alias in preferredTypeAliases:
    if alias.layoutSymbol.len > 0:
      semanticTypeSymbols[alias.nifSymbol] = alias.layoutSymbol
  let preferredLayoutNames = collectPreferredLayoutNames(
    preferredTypeAliases, semanticTypeSymbols, layouts, requiredTypes
  )

  for typ in unmaterializedTypes:
    if typ.typeId in requiredTypes or typ.nifSymbol in requiredTypes:
      result.types.add typ
      represented[typ.typeId] = true

  for describedLayout in description.types:
    let layout = layouts[describedLayout.typeSymbol]
    let hasUnresolvedElement =
      layout.elementTypeSymbol in layouts and
      layouts[layout.elementTypeSymbol].kind in ["genericbody", "genericinvocation"]
    let hasMissingTupleFields =
      layout.kind == "tuple" and layout.size > 0 and layout.record.len == 0
    if layout.typeSymbol notin represented and (
      layout.size >= 0 or layout.kind in ["openarray", "sequence", "set"] or
      layout.kind in ["object", "tuple"] and layout.record.len > 0
    ) and layout.kind.isMaterializedKind and layout.typeSymbol in requiredTypes and
        not hasUnresolvedElement and not hasMissingTupleFields:
      if layout.typeSymbol in preferredLayoutNames:
        let preferredName = preferredLayoutNames[layout.typeSymbol]
        if preferredName in preferredTypeIndexes:
          let index = preferredTypeIndexes[preferredName]
          if result.types[index].kind == ntAlias and
              result.types[index].elementTypeSymbol == result.types[index].typeId:
            let alias = result.types[index]
            var resolved = typeFromLayout(layout)
            resolved.name = preferredName
            resolved.nifSymbol = alias.nifSymbol
            resolved.equivalentTypeSymbols = alias.equivalentTypeSymbols
            if alias.typeId notin resolved.equivalentTypeSymbols:
              resolved.equivalentTypeSymbols.add alias.typeId
            result.types[index] = resolved
          elif layout.typeSymbol notin result.types[index].equivalentTypeSymbols:
            result.types[index].equivalentTypeSymbols.add layout.typeSymbol
        else:
          var typ = typeFromLayout(layout)
          typ.name = preferredName
          result.types.add typ
          preferredTypeIndexes[preferredName] = result.types.high
      else:
        result.types.add typeFromLayout(layout)
      represented[layout.typeSymbol] = true

  var publicTypes: seq[NativeType]
  for typ in result.types:
    if typ.typeId in requiredTypes or typ.nifSymbol in requiredTypes:
      publicTypes.add typ
  result.types = publicTypes

proc readModuleSource*(path: string): string =
  var module = bif.load(path)
  var cursor = module.buf.beginRead()
  let sourceNode = cursor.findDescendantTag("modulesrc")
  let source = sourceNode.findChildKind(StrLit)
  if not source.cursorIsNil:
    result = source.strVal
  cursor.endRead()

proc findSemanticBif*(nimcacheDir, sourcePath: string): string =
  result = findSemanticBifPath(nimcacheDir, sourcePath)

proc readBifNativeApi*(
    nimcacheDir, sourceRoot, sourcePath, libraryName: string,
    exportConfig = NativeExportConfig(),
): NativeApi =
  ## Reconstructs a native API from semantic BIF and compiler C artifacts.
  let
    bifPath = findSemanticBif(nimcacheDir, sourcePath)
    initSymbol = nativeInitSymbol(libraryName, bifPath)
    routines = resolveNativeSymbols(
      nimcacheDir, publicRoutineSymbols(nimcacheDir, sourceRoot, exportConfig)
    )
    hooks = resolveNativeHooks(nimcacheDir, nativeHookSymbols(nimcacheDir, sourceRoot))
    description = bifNativeDescription(
      nimcacheDir, sourceRoot, libraryName, initSymbol, routines, hooks
    )
  result = buildNativeApi(bifPath, description)
