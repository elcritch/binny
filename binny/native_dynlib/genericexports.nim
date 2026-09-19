## Concrete generic specialization evidence from semantic compiler symbols.

import std/[algorithm, sets, strutils, tables]
import nif/[bif, nifcoreparse, nifqueries]
import "$nim"/compiler/astdef

type
  GenericExportError* = object of ValueError
  GenericType = object
    kind: TTypeKind
    nominal: string
    sons: seq[string]
  GenericEvidence* = object
    types: Table[string, GenericType]
    declarations: Table[string, Cursor]
    publicTypes: HashSet[string]
    sources*: Table[string, string]
    offers: Table[string, seq[string]]

proc fail(message: string) {.noreturn.} =
  raise newException(GenericExportError, message)

func moduleId(symbol: string): string = symbol.rsplit('.', 1)[^1]

proc typeSymbol(node: Cursor): string =
  if node.kind in {Symbol, SymbolDef}:
    result = node.symName
  elif node.tagIs("td"):
    result = node.findChildKind(SymbolDef).symName

proc collectTypes(node: Cursor, types: var Table[string, GenericType]) =
  if node.kind != TagLit:
    return
  if node.tagIs("td"):
    var parts: seq[Cursor]
    var child = node.childCursor()
    while child.hasMore:
      parts.add child
      child.skip
    let symbol = parts[0].symName
    let ordinal = parseInt(symbol[2 ..< symbol.find('.', 2)])
    if parts.len < 16 or ordinal notin ord(low(TTypeKind))..ord(high(TTypeKind)):
      fail("invalid generic specialization type: " & symbol)
    var typ = GenericType(kind: TTypeKind(ordinal))
    if parts[11].kind == Symbol:
      typ.nominal = parts[11].symName
    elif parts[11].tagIs("sd"):
      typ.nominal = parts[11].findChildKind(SymbolDef).symName
    for index in 16..<parts.len:
      typ.sons.add parts[index].typeSymbol
    types[symbol] = typ
  var child = node.childCursor()
  while child.hasMore:
    collectTypes(child, types)
    child.skip

proc addModule*(evidence: var GenericEvidence, module: var BifModule, identity, source: string) =
  evidence.sources[identity] = source
  for symbol, visibility, declaration in module.declarations:
    if symbol.moduleId == identity and declaration.tagIs("sd"):
      evidence.declarations[symbol] = declaration
      if visibility == ivExported and not declaration.findChildTag("type0").cursorIsNil:
        evidence.publicTypes.incl symbol
  var root = module.buf.beginRead()
  collectTypes(root, evidence.types)
  var child = root.childCursor()
  while child.hasMore:
    if child.tagIs("offer"):
      var parts = child.childCursor()
      parts.skip # original public generic symbol
      let instance = parts.symName
      parts.skip
      let count = int(parts.intVal)
      parts.skip
      var arguments: seq[string]
      for _ in 0..<count:
        arguments.add parts.symName
        parts.skip
      evidence.offers[instance] = arguments
    child.skip
  root.endRead()

proc instantiatedFrom*(declaration: Cursor): string =
  # ast2nif.writeSymDef ends with constraint, instantiatedFrom, transformedBody.
  var parts: seq[Cursor]
  var child = declaration.childCursor()
  while child.hasMore:
    parts.add child
    child.skip
  if parts.len >= 3 and parts[^2].kind == Symbol:
    result = parts[^2].symName

proc declarationType*(declaration: Cursor): string =
  ## Resolves a declaration's type identity, including references to shared types.
  let descriptor = declaration.findChildTag("td")
  if not descriptor.cursorIsNil:
    return descriptor.typeSymbol
  var child = declaration.childCursor()
  while child.hasMore:
    if child.kind == Symbol and child.symName.startsWith("`t"):
      return child.symName
    child.skip

proc genericParameters(evidence: GenericEvidence, declaration: Cursor): seq[string] =
  var routine = declaration.childCursor()
  while routine.hasMore:
    if routine.kind != TagLit or
        routine.tagName notin ["proc", "func", "method", "converter", "iterator"]:
      routine.skip
      continue
    let parameters = routine.findChildTag("genericparams")
    if parameters.cursorIsNil:
      routine.skip
      continue
    var child = parameters.childCursor()
    while child.hasMore:
      if child.kind == Symbol:
        let parameter = evidence.declarations.getOrDefault(child.symName)
        if not parameter.cursorIsNil:
          result.add parameter.declarationType
      elif child.tagIs("sd"):
        result.add child.declarationType
      child.skip
    return

proc bindTypes(evidence: GenericEvidence, formal, actual: string,
    parameters: HashSet[string], bindings: var Table[string, string]) =
  if formal in parameters:
    if formal in bindings and bindings[formal] != actual:
      fail("conflicting compiler generic bindings for " & formal)
    bindings[formal] = actual
    return
  if formal notin evidence.types or actual notin evidence.types:
    return
  let expected = evidence.types[formal]
  let concrete = evidence.types[actual]
  var concrete_sons = concrete.sons
  if expected.kind == tyGenericInvocation and concrete.kind == tyGenericInst:
    concrete_sons.setLen(concrete_sons.len - 1)
  elif expected.kind != concrete.kind:
    return
  if expected.sons.len != concrete_sons.len:
    return
  for index, son in expected.sons:
    evidence.bindTypes(son, concrete_sons[index], parameters, bindings)

proc typeExpression(evidence: GenericEvidence, symbol: string,
    sources: var seq[string], visiting: var HashSet[string]): string =
  if symbol notin evidence.types or symbol in visiting:
    fail("cannot render compiler generic argument " & symbol)
  visiting.incl symbol
  defer: visiting.excl symbol
  let typ = evidence.types[symbol]
  if typ.nominal in evidence.publicTypes and typ.kind notin {tyGenericInst, tyGenericInvocation}:
    let identity = typ.nominal.moduleId
    let source = evidence.sources[identity]
    if source notin sources: sources.add source
    let name = typ.nominal.split('.')[0]
    return "binnyGenericModule_" & identity & ".`" & name & "`"
  case typ.kind
  of tyBool: result = "bool"
  of tyChar: result = "char"
  of tyInt: result = "int"
  of tyInt8: result = "int8"
  of tyInt16: result = "int16"
  of tyInt32: result = "int32"
  of tyInt64: result = "int64"
  of tyUInt: result = "uint"
  of tyUInt8: result = "uint8"
  of tyUInt16: result = "uint16"
  of tyUInt32: result = "uint32"
  of tyUInt64: result = "uint64"
  of tyFloat: result = "float"
  of tyFloat32: result = "float32"
  of tyFloat64: result = "float64"
  of tyString: result = "string"
  of tyCstring: result = "cstring"
  of tyPointer: result = "pointer"
  of tyAlias:
    result = evidence.typeExpression(typ.sons[^1], sources, visiting)
  of tyGenericInst, tyGenericInvocation:
    result = evidence.typeExpression(typ.sons[0], sources, visiting) & "["
    let limit = typ.sons.len - ord(typ.kind == tyGenericInst)
    for index in 1..<limit:
      if index > 1: result.add ", "
      result.add evidence.typeExpression(typ.sons[index], sources, visiting)
    result.add "]"
  of tySequence, tySet, tyUncheckedArray, tyPtr, tyRef:
    let container = case typ.kind
      of tySequence: "seq["
      of tySet: "set["
      of tyUncheckedArray: "UncheckedArray["
      of tyPtr: "ptr "
      else: "ref "
    result = container & evidence.typeExpression(typ.sons[^1], sources, visiting)
    if container.endsWith("["): result.add "]"
  else:
    fail("generic argument needs a public type declaration: " & symbol)

proc specializationArguments*(evidence: GenericEvidence, origin, instance: Cursor,
    sources: var seq[string]): seq[string] =
  let instance_symbol = instance.findChildKind(SymbolDef).symName
  if instance_symbol in evidence.offers:
    for argument in evidence.offers[instance_symbol]:
      var visiting = initHashSet[string]()
      result.add evidence.typeExpression(argument, sources, visiting)
    return
  let parameters = evidence.genericParameters(origin)
  var parameter_set = initHashSet[string]()
  for parameter in parameters: parameter_set.incl parameter
  var bindings: Table[string, string]
  proc signatureTypes(declaration: Cursor): seq[string] =
    let formals = declaration.findChildTag("td").findChildTag("formalparams")
    if formals.cursorIsNil: return
    var child = formals.childCursor()
    child.skip # flags
    result.add child.typeSymbol
    let owner = declaration.findChildKind(SymbolDef).symName
    var params: seq[tuple[position: int, symbol: string]]
    proc collectParams(node: Cursor) =
      if node.kind != TagLit: return
      if node.tagIs("sd") and not node.findChildTag("param").cursorIsNil:
        var parts: seq[Cursor]
        var part = node.childCursor()
        while part.hasMore:
          parts.add part
          part.skip
        if parts.len > 10 and parts[10].kind == Symbol and parts[10].symName == owner:
          params.add (int(parts[7].intVal), node.declarationType)
      else:
        var part = node.childCursor()
        while part.hasMore:
          collectParams(part)
          part.skip
    collectParams(formals)
    params.sort(proc(a, b: tuple[position: int, symbol: string]): int = cmp(a.position, b.position))
    for param in params: result.add param.symbol
  let formal_types = signatureTypes(origin)
  let actual_types = signatureTypes(instance)
  if formal_types.len != actual_types.len:
    fail("compiler generic signature arity mismatch")
  for index, formal in formal_types:
    evidence.bindTypes(formal, actual_types[index], parameter_set, bindings)
  for parameter in parameters:
    if parameter notin bindings:
      fail("compiler did not preserve concrete generic argument " & parameter &
        " in " & origin.findChildKind(SymbolDef).symName & " -> " &
        instance.findChildKind(SymbolDef).symName & ": " &
        $evidence.types.getOrDefault(origin.declarationType).sons & " -> " &
        $evidence.types.getOrDefault(instance.declarationType).sons)
    var visiting = initHashSet[string]()
    result.add evidence.typeExpression(bindings[parameter], sources, visiting)
  if result.len == 0:
    fail("compiler did not preserve generic parameters for exported instance")

proc originDeclaration*(evidence: GenericEvidence, symbol: string): Cursor =
  evidence.declarations.getOrDefault(symbol)

proc signatureKey*(evidence: GenericEvidence, declaration: Cursor): string =
  proc identity(symbol: string): string =
    if symbol notin evidence.types: return symbol
    let typ = evidence.types[symbol]
    if typ.kind == tyAlias: return identity(typ.sons[^1])
    if typ.nominal.len > 0 and typ.kind notin {tyGenericInst, tyGenericInvocation}:
      return $typ.kind & ":" & typ.nominal
    result = $typ.kind
    let limit = typ.sons.len - ord(typ.kind == tyGenericInst)
    for index in 0..<limit:
      result.add "[" & identity(typ.sons[index]) & "]"
  let descriptor = declaration.findChildTag("td")
  if descriptor.cursorIsNil:
    let type_id = declaration.declarationType
    if type_id notin evidence.types or evidence.types[type_id].kind != tyProc:
      fail("missing compiler routine type for " & declaration.findChildKind(SymbolDef).symName)
    let typ = evidence.types[type_id]
    for index in 1..<typ.sons.len:
      result.add "\x1f" & identity(typ.sons[index])
    return
  let owner = declaration.findChildKind(SymbolDef).symName
  var params: seq[tuple[position: int, typ: string]]
  proc collect(node: Cursor) =
    if node.kind != TagLit: return
    if node.tagIs("sd") and not node.findChildTag("param").cursorIsNil:
      var parts: seq[Cursor]
      var child = node.childCursor()
      while child.hasMore:
        parts.add child
        child.skip
      if parts[10].kind == Symbol and parts[10].symName == owner:
        params.add (int(parts[7].intVal), identity(node.declarationType))
    else:
      var child = node.childCursor()
      while child.hasMore:
        collect(child)
        child.skip
  collect(descriptor.findChildTag("formalparams"))
  params.sort(proc(a, b: tuple[position: int, typ: string]): int = cmp(a.position, b.position))
  for param in params: result.add "\x1f" & param.typ
