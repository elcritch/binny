import std/[os, strutils, tables]
import ./nif/[bif, nifcoreparse, nifqueries]
import model

type
  NativeBifError* = object of ValueError

  AbiProcEntry = object
    nifSymbol: string
    nimName: string
    cSymbol: string
    signatureFingerprint: string
    genericInstance: bool
    returnTypeSymbol: string
    returnLowering: NativeLoweringMode
    callConv: string
    closureEnv: bool
    varargs: bool
    params: seq[NativeParam]

  AbiHookEntry = object
    typeSymbol: string
    kind: string
    nifSymbol: string
    cSymbol: string
    status: NativeHookStatus

  AbiManifest = object
    formatVersion: int64
    abiId: string
    libraryName: string
    compilerVersion: string
    compilerApiVersion: int64
    rodVersion: string
    targetOS: string
    targetCPU: string
    targetEndian: string
    targetBits: int64
    memoryManager: string
    allocator: string
    exceptionSystem: string
    stringMode: string
    threads: bool
    initSymbol: string
    modules: seq[NativeModule]
    types: seq[AbiTypeEntry]
    hooks: seq[AbiHookEntry]
    procs: seq[AbiProcEntry]

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

proc fail(message: string) {.noinline, noreturn.} =
  raise newException(NativeBifError, message)

proc readStrings(node: Cursor, field: string, count: int): seq[string] =
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == StrLit:
      result.add children.strVal
    else:
      fail("native ABI manifest " & field & " has an invalid field")
    children.skip
  if result.len != count:
    fail("native ABI manifest " & field & " expects " & $count & " string value(s)")

proc takeString(children: var Cursor, field: string): string =
  if not children.hasMore or children.kind != StrLit:
    fail("native ABI manifest " & field & " expects a string")
  result = children.strVal
  children.skip

proc takeIdent(children: var Cursor, field: string): string =
  if not children.hasMore or children.kind != Ident:
    fail("native ABI manifest " & field & " expects an identifier")
  result = children.strVal
  children.skip

proc takeInt(children: var Cursor, field: string): int64 =
  if not children.hasMore or children.kind != IntLit:
    fail("native ABI manifest " & field & " expects an integer")
  result = children.intVal
  children.skip

proc takeLayoutInt(children: var Cursor, field: string): int64 =
  if not children.hasMore:
    fail("native ABI manifest " & field & " expects a layout integer")
  case children.kind
  of IntLit:
    result = children.intVal
  of Ident:
    if children.strVal != "unknown":
      fail("native ABI manifest " & field & " has an invalid layout value")
    result = -1
  else:
    fail("native ABI manifest " & field & " expects a layout integer")
  children.skip

proc parseBool(value, field: string): bool =
  case value
  of "true":
    result = true
  of "false":
    result = false
  else:
    fail("native ABI manifest " & field & " expects true or false")

proc parseLoweringMode(value: string): NativeLoweringMode =
  case value
  of "void":
    nlVoid
  of "direct":
    nlDirect
  of "indirect":
    nlIndirect
  of "pointer":
    nlPointer
  else:
    fail("native ABI manifest has an invalid lowering mode: " & value)

proc parseAbiParameter(node: Cursor): NativeParam =
  var children = node.childCursor()
  result.name = takeString(children, "parameter name")
  result.typeSymbol = takeString(children, "parameter type")
  result.lowering = parseLoweringMode(takeIdent(children, "parameter lowering"))
  result.hiddenLengthCount = int(takeInt(children, "parameter hidden lengths"))
  if children.hasMore:
    fail("native ABI manifest parameter has extra fields")

proc parseAbiLowering(node: Cursor, result: var AbiProcEntry) =
  var children = node.childCursor()
  while children.hasMore:
    if children.kind != TagLit:
      fail("native ABI manifest lowering contains an invalid entry")
    case children.tagName
    of "callconv":
      result.callConv = readStrings(children, "callconv", 1)[0]
    of "result":
      var values = children.childCursor()
      result.returnTypeSymbol = takeString(values, "result type")
      result.returnLowering = parseLoweringMode(takeIdent(values, "result lowering"))
      if values.hasMore:
        fail("native ABI manifest result has extra fields")
    of "parameters":
      var values = children.childCursor()
      while values.hasMore:
        if values.kind == TagLit and values.tagName == "parameter":
          result.params.add parseAbiParameter(values)
        elif values.kind != DotToken:
          fail("native ABI manifest parameters contains an invalid entry")
        values.skip
    of "closureenv":
      var values = children.childCursor()
      result.closureEnv =
        parseBool(takeIdent(values, "closure environment"), "closure environment")
      if values.hasMore:
        fail("native ABI manifest closureenv has extra fields")
    of "varargs":
      var values = children.childCursor()
      result.varargs = parseBool(takeIdent(values, "varargs"), "varargs")
      if values.hasMore:
        fail("native ABI manifest varargs has extra fields")
    else:
      fail("native ABI manifest lowering has an unknown entry")
    children.skip

proc parseAbiProc(node: Cursor): AbiProcEntry =
  var values: seq[string] = @[]
  var hasGenericInstance = false
  var children = node.childCursor()
  while children.hasMore:
    case children.kind
    of StrLit:
      values.add children.strVal
    of Ident:
      if hasGenericInstance:
        fail("native ABI manifest proc has duplicate generic flag")
      case children.strVal
      of "true":
        result.genericInstance = true
      of "false":
        result.genericInstance = false
      else:
        fail("native ABI manifest proc has invalid generic flag")
      hasGenericInstance = true
    of TagLit:
      if children.tagName != "lowering":
        fail("native ABI manifest proc has an invalid subtree")
      parseAbiLowering(children, result)
    else:
      fail("native ABI manifest proc has an invalid field")
    children.skip

  if values.len != 4 or not hasGenericInstance or result.callConv.len == 0:
    fail("native ABI manifest proc has an invalid shape")
  result.nifSymbol = values[0]
  result.nimName = values[1]
  result.cSymbol = values[2]
  result.signatureFingerprint = values[3]

proc parseAbiProcs(node: Cursor): seq[AbiProcEntry] =
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == TagLit and children.tagName == "proc":
      result.add parseAbiProc(children)
    elif children.kind != DotToken:
      fail("native ABI manifest procs contains an invalid entry")
    children.skip

proc parseAbiHook(node: Cursor): AbiHookEntry =
  var values: seq[string] = @[]
  var hasStatus = false
  var children = node.childCursor()
  while children.hasMore:
    case children.kind
    of StrLit:
      values.add children.strVal
    of Ident:
      if hasStatus:
        fail("native ABI manifest hook has duplicate status")
      case children.strVal
      of "custom":
        result.status = nhCustom
      of "forbidden":
        result.status = nhForbidden
      else:
        fail("native ABI manifest hook has invalid status")
      hasStatus = true
    of DotToken:
      discard
    else:
      fail("native ABI manifest hook has an invalid field")
    children.skip

  if not hasStatus or values.len notin {3, 4}:
    fail("native ABI manifest hook has an invalid shape")
  result.typeSymbol = values[0]
  result.kind = values[1]
  result.nifSymbol = values[2]
  if result.status == nhCustom:
    if values.len != 4:
      fail("custom native ABI hook has no linker symbol")
    result.cSymbol = values[3]
  elif values.len != 3:
    fail("forbidden native ABI hook has a linker symbol")

proc parseAbiHooks(node: Cursor): seq[AbiHookEntry] =
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == TagLit and children.tagName == "hook":
      result.add parseAbiHook(children)
    elif children.kind != DotToken:
      fail("native ABI manifest hooks contains an invalid entry")
    children.skip

proc parseAbiModules(node: Cursor): seq[NativeModule] =
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == TagLit and children.tagName == "module":
      let values = readStrings(children, "module", 2)
      result.add NativeModule(identity: values[0], name: values[1])
    elif children.kind != DotToken:
      fail("native ABI manifest modules contains an invalid entry")
    children.skip

proc parseAbiField(node: Cursor): NativeField =
  var children = node.childCursor()
  result.name = takeString(children, "field name")
  result.typeSymbol = takeString(children, "field type")
  result.offset = takeLayoutInt(children, "field offset")
  result.size = takeLayoutInt(children, "field size")
  result.alignment = takeLayoutInt(children, "field alignment")
  case takeIdent(children, "field visibility")
  of "exported":
    result.exported = true
  of "private":
    result.exported = false
  else:
    fail("native ABI manifest field has invalid visibility")
  case takeIdent(children, "field management")
  of "managed":
    result.managed = true
  of "plain":
    result.managed = false
  else:
    fail("native ABI manifest field has invalid management")
  case takeIdent(children, "field role")
  of "discriminant":
    result.discriminant = true
  of "field":
    result.discriminant = false
  else:
    fail("native ABI manifest field has invalid role")
  if children.hasMore:
    fail("native ABI manifest field has extra fields")

proc parseAbiRecord(node: Cursor): seq[NativeRecordPart]

proc parseAbiBranch(node: Cursor): NativeBranch =
  var children = node.childCursor()
  result.index = int(takeInt(children, "branch index"))
  case takeIdent(children, "branch kind")
  of "else":
    result.isElse = true
  of "of":
    result.isElse = false
  else:
    fail("native ABI manifest branch has invalid kind")

  while children.hasMore:
    if children.kind != TagLit:
      fail("native ABI manifest branch contains an invalid entry")
    case children.tagName
    of "selectors":
      var selectors = children.childCursor()
      while selectors.hasMore:
        result.selectors.add takeString(selectors, "branch selector")
    of "record":
      result.record = parseAbiRecord(children)
    else:
      fail("native ABI manifest branch has an unknown entry")
    children.skip

proc parseAbiCase(node: Cursor): NativeRecordPart =
  result = NativeRecordPart(kind: nrCase)
  var children = node.childCursor()
  while children.hasMore:
    if children.kind != TagLit:
      fail("native ABI manifest case contains an invalid entry")
    case children.tagName
    of "field":
      if result.discriminant.name.len > 0:
        fail("native ABI manifest case has duplicate discriminants")
      result.discriminant = parseAbiField(children)
    of "branch":
      result.branches.add parseAbiBranch(children)
    else:
      fail("native ABI manifest case has an unknown entry")
    children.skip
  if result.discriminant.name.len == 0 or result.branches.len == 0:
    fail("native ABI manifest case is incomplete")

proc parseAbiRecord(node: Cursor): seq[NativeRecordPart] =
  var children = node.childCursor()
  while children.hasMore:
    if children.kind != TagLit:
      fail("native ABI manifest record contains an invalid entry")
    case children.tagName
    of "field":
      result.add NativeRecordPart(kind: nrField, field: parseAbiField(children))
    of "case":
      result.add parseAbiCase(children)
    else:
      fail("native ABI manifest record has an unknown entry")
    children.skip

proc parseAbiType(node: Cursor): AbiTypeEntry =
  var children = node.childCursor()
  result.typeSymbol = takeString(children, "type symbol")
  result.kind = takeIdent(children, "type kind")
  result.size = takeLayoutInt(children, "type size")
  result.alignment = takeLayoutInt(children, "type alignment")
  result.layoutFingerprint = takeString(children, "layout fingerprint")
  discard takeIdent(children, "type management")
  case takeIdent(children, "type packing")
  of "packed":
    result.packed = true
  of "unpacked":
    result.packed = false
  else:
    fail("native ABI manifest type has invalid packing")
  case takeIdent(children, "type union mode")
  of "union":
    result.union = true
  of "regular":
    result.union = false
  else:
    fail("native ABI manifest type has invalid union mode")
  case takeIdent(children, "type inheritance")
  of "inheritable":
    result.inheritable = true
  of "final":
    result.inheritable = false
  else:
    fail("native ABI manifest type has invalid inheritance")
  while children.hasMore:
    if children.kind != TagLit:
      fail("native ABI manifest type contains an invalid entry")
    case children.tagName
    of "base":
      result.baseTypeSymbol = readStrings(children, "base", 1)[0]
    of "element":
      result.elementTypeSymbol = readStrings(children, "element", 1)[0]
    of "record":
      result.record = parseAbiRecord(children)
    of "enum":
      var values = children.childCursor()
      while values.hasMore:
        if values.kind != TagLit or values.tagName != "value":
          fail("native ABI manifest enum contains an invalid entry")
        var enumValue = values.childCursor()
        result.enumValues.add NativeEnumValue(
          name: takeString(enumValue, "enum value name"),
          ordinal: takeInt(enumValue, "enum value ordinal"),
        )
        if enumValue.hasMore:
          fail("native ABI manifest enum value has extra fields")
        values.skip
    else:
      fail("native ABI manifest type has an unknown entry")
    children.skip

proc parseAbiTypes(node: Cursor): seq[AbiTypeEntry] =
  var children = node.childCursor()
  while children.hasMore:
    if children.kind == TagLit and children.tagName == "type":
      result.add parseAbiType(children)
    elif children.kind != DotToken:
      fail("native ABI manifest types contains an invalid entry")
    children.skip

proc readAbiManifest(path: string): AbiManifest =
  var manifest = nifcoreparse.parseFromFile(path)
  var cursor = manifest.beginRead()
  if cursor.kind != TagLit or cursor.tagName != "abi":
    fail("native ABI manifest has no abi root")

  result.formatVersion = -1
  cursor.loopInto:
    if cursor.kind == TagLit:
      case cursor.tagName
      of "format":
        var values = cursor.childCursor()
        if not values.hasMore or values.kind != IntLit:
          fail("native ABI manifest has no format version")
        result.formatVersion = values.intVal
        values.skip
        if values.hasMore:
          fail("native ABI manifest format has extra fields")
      of "compiler":
        if result.formatVersion != 4:
          fail("unsupported native ABI manifest format: " & $result.formatVersion)
        var values = cursor.childCursor()
        result.compilerVersion = takeString(values, "compiler version")
        result.compilerApiVersion = takeInt(values, "compiler API version")
        result.rodVersion = takeString(values, "rod version")
        if values.hasMore:
          fail("native ABI manifest compiler has extra fields")
      of "abiid":
        result.abiId = readStrings(cursor, "abiid", 1)[0]
      of "target":
        var values = cursor.childCursor()
        result.targetOS = takeString(values, "target OS")
        result.targetCPU = takeString(values, "target CPU")
        result.targetEndian = takeString(values, "target endianness")
        result.targetBits = takeInt(values, "target bits")
        if values.hasMore:
          fail("native ABI manifest target has extra fields")
      of "runtime":
        var values = cursor.childCursor()
        result.memoryManager = takeString(values, "memory manager")
        result.allocator = takeString(values, "allocator")
        result.exceptionSystem = takeString(values, "exception system")
        result.stringMode = takeString(values, "string mode")
        result.threads = parseBool(takeIdent(values, "threads"), "threads")
        result.initSymbol = takeString(values, "initialization symbol")
        if values.hasMore:
          fail("native ABI manifest runtime has extra fields")
      of "library":
        result.libraryName = readStrings(cursor, "library", 1)[0]
      of "modules":
        result.modules = parseAbiModules(cursor)
      of "types":
        result.types = parseAbiTypes(cursor)
      of "hooks":
        result.hooks = parseAbiHooks(cursor)
      of "procs":
        result.procs = parseAbiProcs(cursor)
      else:
        discard
    cursor.skip
  cursor.endRead()

  if result.formatVersion != 4:
    fail("unsupported native ABI manifest format")
  if result.abiId.len == 0 or result.compilerVersion.len == 0 or result.targetOS.len == 0 or
      result.targetCPU.len == 0 or result.memoryManager.len == 0 or
      result.allocator.len == 0 or result.libraryName.len == 0 or result.modules.len == 0 or
      result.types.len == 0 or result.initSymbol.len == 0:
    fail("native ABI manifest is missing target metadata")

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
    let indexTypeNode = instanceType.findChildTag("ident")
    if not indexTypeNode.cursorIsNil:
      let indexType = indexTypeNode.findChildKind(Ident)
      if not indexType.cursorIsNil:
        typ.indexTypeSymbol = indexType.strVal
  else:
    return false
  result = true

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

proc parseNativeProc(
    declaration: Cursor, abi: AbiProcEntry, applyAbiLowering = true
): NativeProc =
  result.name = symbolBase(abi.nifSymbol)
  result.nifSymbol = abi.nifSymbol
  result.cSymbol = abi.cSymbol
  result.returnLowering = abi.returnLowering
  result.callConv = abi.callConv
  result.closureEnv = abi.closureEnv
  result.varargs = abi.varargs
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
    children.skip
  proc collectParams(node: Cursor, params: var seq[NativeParam]) =
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
            params.add parseParam(nested)
        else:
          collectParams(nested, params)
      nested.skip

  collectParams(formals, result.params)

  if applyAbiLowering:
    result.returnTypeSymbol = abi.returnTypeSymbol
    if result.params.len != abi.params.len:
      fail(
        "semantic parameter count does not match ABI lowering for " & abi.nifSymbol &
          ": semantic=" & $result.params.len & " ABI=" & $abi.params.len
      )
    var orderedParams: seq[NativeParam]
    for abiParam in abi.params:
      var found = false
      for param in result.params:
        if param.name == abiParam.name:
          orderedParams.add param
          found = true
          break
      if not found:
        fail("semantic parameter not found for " & abi.nifSymbol & ": " & abiParam.name)
    result.params = orderedParams
    for i in 0 ..< result.params.len:
      if not result.params[i].byVar:
        result.params[i].typeSymbol = abi.params[i].typeSymbol
      result.params[i].lowering = abi.params[i].lowering
      result.params[i].hiddenLengthCount = abi.params[i].hiddenLengthCount

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
  kind in ["object", "enum", "distinct", "array", "sequence", "set", "tuple"]

proc addLayoutDependency(
    layoutSymbol: string,
    layouts: Table[string, AbiTypeEntry],
    dependencies: var Table[string, bool]
)

proc collectLayoutDependencies(
    layout: AbiTypeEntry,
    layouts: Table[string, AbiTypeEntry],
    dependencies: var Table[string, bool]
)

proc collectRecordDependencies(
    record: seq[NativeRecordPart],
    layouts: Table[string, AbiTypeEntry],
    dependencies: var Table[string, bool]
)

proc collectBranchDependencies(
    branches: seq[NativeBranch],
    layouts: Table[string, AbiTypeEntry],
    dependencies: var Table[string, bool]
) =
  for branch in branches:
    collectRecordDependencies(branch.record, layouts, dependencies)

proc collectRecordDependencies(
    record: seq[NativeRecordPart],
    layouts: Table[string, AbiTypeEntry],
    dependencies: var Table[string, bool]
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
    dependencies: var Table[string, bool]
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
    dependencies: var Table[string, bool]
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
  layout.size < 0 or layout.kind in ["genericbody", "genericinvocation"]

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
  collectReferencedLayoutDependencies(layouts[symbol], layouts, requiredTypes, skipInternal)

proc collectReferencedBranchDependencies(
    branches: seq[NativeBranch],
    layouts: Table[string, AbiTypeEntry],
    requiredTypes: var Table[string, bool],
    skipInternal: Table[string, bool],
) =
  for branch in branches:
    collectReferencedRecordDependencies(branch.record, layouts, requiredTypes, skipInternal)

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
      collectReferencedType(part.discriminant.typeSymbol, layouts, requiredTypes, skipInternal)
      collectReferencedBranchDependencies(part.branches, layouts, requiredTypes, skipInternal)

proc collectReferencedLayoutDependencies(
    layout: AbiTypeEntry,
    layouts: Table[string, AbiTypeEntry],
    requiredTypes: var Table[string, bool],
    skipInternal: Table[string, bool],
) =
  collectReferencedType(layout.baseTypeSymbol, layouts, requiredTypes, skipInternal)
  collectReferencedType(layout.elementTypeSymbol, layouts, requiredTypes, skipInternal)
  collectReferencedRecordDependencies(layout.record, layouts, requiredTypes, skipInternal)

proc addAbiModule(
    modules: var seq[bif.BifModule], seenPaths: var Table[string, bool], path: string
) =
  let normalized = normalizedPath(absolutePath(path))
  if normalized notin seenPaths:
    if not fileExists(normalized):
      fail("semantic BIF not found: " & normalized)
    seenPaths[normalized] = true
    modules.add bif.load(normalized)

proc loadAbiModules(bifPath: string, manifest: AbiManifest): seq[bif.BifModule] =
  let nimcacheDir = bifPath.parentDir
  var seenPaths: Table[string, bool]
  addAbiModule(result, seenPaths, bifPath)
  for module in manifest.modules:
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

proc readNativeApi*(bifPath, manifestPath: string): NativeApi =
  let manifest = readAbiManifest(manifestPath)
  result.abiId = manifest.abiId
  result.libraryName = manifest.libraryName
  result.compilerVersion = manifest.compilerVersion
  result.compilerApiVersion = manifest.compilerApiVersion
  result.rodVersion = manifest.rodVersion
  result.targetOS = manifest.targetOS
  result.targetCPU = manifest.targetCPU
  result.targetEndian = manifest.targetEndian
  result.targetBits = manifest.targetBits
  result.memoryManager = manifest.memoryManager
  result.allocator = manifest.allocator
  result.exceptionSystem = manifest.exceptionSystem
  result.stringMode = manifest.stringMode
  result.threads = manifest.threads
  result.initSymbol = manifest.initSymbol
  result.modules = manifest.modules

  var layouts: Table[string, AbiTypeEntry]
  for layout in manifest.types:
    layouts[layout.typeSymbol] = layout

  var modules = loadAbiModules(bifPath, manifest)
  var skipSystemModuleTypeSymbols: Table[string, bool]
  var stdTablesModules: Table[string, bool]
  var manifestTypeSymbols: Table[string, bool]
  for item in manifest.procs:
    if item.returnTypeSymbol.len > 0:
      manifestTypeSymbols[item.returnTypeSymbol] = true
    for param in item.params:
      manifestTypeSymbols[param.typeSymbol] = true
  for module in manifest.modules:
    if module.name == "system":
      skipSystemModuleTypeSymbols[module.identity] = true
    if module.name == "tables":
      let path = bifPath.parentDir / (module.identity & ".s.bif")
      if readModuleSource(path).isStdTablesSource:
        stdTablesModules[module.identity] = true

  var importedGenericTypes: Table[string, NativeType]
  var skipStdTableObjectTypes: Table[string, bool]
  var unmaterializedTypes: seq[NativeType]
  for module in modules.mitems:
    for nifSymbol, visibility, declaration in module.declarations:
      let moduleId = symbolModule(nifSymbol)
      if visibility == ivExported or moduleId.len > 0 and not (moduleId in skipSystemModuleTypeSymbols):
        if not declaration.findChildTag("type").cursorIsNil and
            not declaration.findChildTag("type0").cursorIsNil:
          collectStdOrderedTables(
            declaration,
            stdTablesModules,
            layouts,
            importedGenericTypes,
            skipStdTableObjectTypes,
          )
          var typ: NativeType
          if parseNativeType(declaration, nifSymbol, typ):
            if visibility != ivExported and typ.kind != ntAlias and
                typ.typeId notin manifestTypeSymbols and typ.nifSymbol notin manifestTypeSymbols:
              continue
            let hasLayout = applyLayout(typ, layouts)
            if typ.kind != ntAlias and not hasLayout:
              typ.size = -1
              typ.alignment = -1
              unmaterializedTypes.add typ
              continue
            if not hasLayout:
              typ.size = -1
              typ.alignment = -1
            if symbolModule(typ.nifSymbol) in stdTablesModules and
                symbolBase(typ.nifSymbol) == "OrderedTable":
              continue
            if typ.nifSymbol in skipStdTableObjectTypes or typ.typeId in skipStdTableObjectTypes:
              continue
            result.types.add typ

  for typ in importedGenericTypes.values:
    result.types.add typ

  var represented: Table[string, bool]
  for typ in result.types:
    represented[typ.typeId] = true

  var internalLayoutTypes: Table[string, bool]
  for typ in importedGenericTypes.values:
    addLayoutDependency(typ.typeId, layouts, internalLayoutTypes)

  for item in manifest.procs:
    if item.genericInstance:
      fail(
        "concrete generic exports need signature materialization support: " &
          item.cSymbol
      )
    let nifSymbol = item.nifSymbol
    let declaration = findSemanticDeclaration(modules, nifSymbol)
    if declaration.cursorIsNil:
      fail("semantic declaration not found for " & nifSymbol)
    result.procs.add parseNativeProc(declaration, item)

  for item in manifest.hooks:
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
          nifSymbol: item.nifSymbol,
          cSymbol: item.cSymbol,
          callConv: "nimcall",
          returnLowering: nlDirect,
          params: @[],
        ),
        applyAbiLowering = false,
      ),
    )

  var skipInternalTypes = internalLayoutTypes
  for typ in importedGenericTypes.values:
    skipInternalTypes[typ.typeId] = true

  var requiredTypes: Table[string, bool]
  for typ in result.types:
    let isManifestType =
      typ.nifSymbol in manifestTypeSymbols or typ.typeId in manifestTypeSymbols
    let isMaterializedSemanticType = typ.kind != ntAlias
    if typ.kind == ntImportedGeneric or isManifestType or isMaterializedSemanticType:
      let moduleIdentity = symbolModule(typ.nifSymbol)
      if moduleIdentity.len > 0 and moduleIdentity in skipSystemModuleTypeSymbols:
        continue
      let symbolSkip =
        if typ.kind == ntImportedGeneric:
          skipInternalTypes
        else:
          initTable[string, bool]()
      collectReferencedType(typ.typeId, layouts, requiredTypes, symbolSkip)
      if typ.kind == ntAlias:
        collectReferencedType(typ.elementTypeSymbol, layouts, requiredTypes, symbolSkip)

  for procInfo in result.procs:
    collectReferencedType(procInfo.returnTypeSymbol, layouts, requiredTypes, skipInternalTypes)
    for param in procInfo.params:
      collectReferencedType(param.typeSymbol, layouts, requiredTypes, skipInternalTypes)
  for hook in result.hooks:
    collectReferencedType(hook.procInfo.returnTypeSymbol, layouts, requiredTypes, skipInternalTypes)
    for param in hook.procInfo.params:
      collectReferencedType(param.typeSymbol, layouts, requiredTypes, skipInternalTypes)
  for symbol in manifestTypeSymbols.keys:
    requiredTypes[symbol] = true

  for typ in unmaterializedTypes:
    if typ.typeId in requiredTypes or typ.nifSymbol in requiredTypes:
      result.types.add typ
      represented[typ.typeId] = true

  for layout in manifest.types:
    let hasUnresolvedElement =
      layout.elementTypeSymbol in layouts and
      layouts[layout.elementTypeSymbol].kind in ["genericbody", "genericinvocation"]
    let hasMissingTupleFields =
      layout.kind == "tuple" and layout.size > 0 and layout.record.len == 0
    if layout.typeSymbol notin represented and layout.size >= 0 and
        layout.kind.isMaterializedKind and
        layout.typeSymbol in requiredTypes and
        not hasUnresolvedElement and not hasMissingTupleFields:
      result.types.add typeFromLayout(layout)
      represented[layout.typeSymbol] = true

  var publicTypes: seq[NativeType]
  for typ in result.types:
    if typ.kind == ntImportedGeneric or typ.typeId in requiredTypes or typ.nifSymbol in requiredTypes:
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
  let expected = normalizedPath(absolutePath(sourcePath))
  for path in walkFiles(nimcacheDir / "*.s.bif"):
    let candidate = readModuleSource(path)
    if candidate.len > 0 and normalizedPath(absolutePath(candidate)) == expected:
      return path
  raise newException(IOError, "semantic BIF not found for: " & sourcePath)
