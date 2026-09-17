## Builds a native Nim export surface from semantic BIF and compiler artifacts.
##
## This module matches public routine declarations from semantic BIF to compiler
## C artifacts, keeps the selected routines live across whole-program dead-code
## elimination, and promotes their Mach-O or ELF symbols after archiving.

import std/[algorithm, cmdline, json, os, osproc, sets, streams, strutils, tables, tempfiles]
import nif/[bif, nifcore, nifcoreparse, nifqueries]
import exportconfig
import genericexports

type
  NativeStaticLibError* = object of CatchableError

  NativeCodegenBackend* = enum
    ncbC
    ncbIncremental

  NativeExportSymbol* = object
    sourcePath*: string
    nifSymbol*: string
    ## Methods use their dispatcher for calls, while retaining the source
    ## declaration for ABI signature reconstruction and export selection.
    backendNifSymbol*: string
    cSymbol*: string
    iteratorRoutine*: bool
    inlineRoutine: bool
    sourceLine, sourceColumn: int
    genericArguments: seq[string]
    genericSources: seq[string]
    genericOrigin: string
    genericArgumentSelectors: seq[string]
    genericSignature: string

  NativeHookSymbol* = object
    sourcePath*: string
    typeSymbol*: string
    typeName*: string
    hookKind*: string
    nifSymbol*: string
    cSymbol*: string
    forbidden*: bool

  NativeOpaqueExport* = object
    sourcePath*, typeName*, nifSymbol*, hookPrefix*: string

  CDefinition = object
    nifSymbol: string
    cSymbol: string
    flags: string

const
  routineKinds = ["proc", "func", "method", "converter", "iterator"]
  hookKinds = ["=destroy", "=copy", "=dup", "=sink", "=trace", "=wasMoved"]
  machMagic64 = 0xfeedfacf'u32
  loadCommandSymtab = 0x2'u32
  machHeader64Size = 32
  nlist64Size = 16
  nTypeExternal = 0x01'u8
  nTypeMask = 0x0e'u8
  nTypeUndefined = 0x00'u8
  nTypePrivateExternal = 0x10'u8
  elfClass64 = 2'u8
  elfDataLittleEndian = 1'u8
  elfHeader64Size = 64
  elfSectionHeader64Size = 64
  elfSymbol64Size = 24
  elfSectionSymbolTable = 2'u32
  elfSectionDynamicSymbols = 11'u32
  elfUndefinedSection = 0'u16
  elfBindingGlobal = 1'u8
  elfBindingWeak = 2'u8
  elfVisibilityMask = 0x03'u8

proc fail(message: string) {.noreturn.} =
  raise newException(NativeStaticLibError, message)

func semanticModule(symbol: string): string =
  let separator = symbol.rfind('.')
  if separator >= 0:
    result = symbol[separator + 1 ..^ 1]

func semanticName(symbol: string): string =
  let moduleSeparator = symbol.rfind('.')
  if moduleSeparator < 0:
    return symbol
  let qualifiedName = symbol[0 ..< moduleSeparator]
  let overloadSeparator = qualifiedName.rfind('.')
  if overloadSeparator < 0:
    result = qualifiedName
  else:
    result = qualifiedName[0 ..< overloadSeparator]

func semanticOverload(symbol: string): string =
  let moduleSeparator = symbol.rfind('.')
  if moduleSeparator < 0:
    return
  let
    qualifiedName = symbol[0 ..< moduleSeparator]
    overloadSeparator = qualifiedName.rfind('.')
  if overloadSeparator >= 0:
    result = qualifiedName[overloadSeparator + 1 ..^ 1]

func mangleCName(value: string): string =
  var requiresUnderscore = false
  for index, character in value:
    template special(replacement: string) =
      result.add replacement
      requiresUnderscore = true

    case character
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9':
      if index == 0 and character in {'0' .. '9'}:
        result.add 'X'
      result.add character
    of '_':
      if index == 0 or index == value.high or value[index + 1] notin {'0' .. '9'}:
        result.add character
    of '$':
      special("dollar")
    of '%':
      special("percent")
    of '&':
      special("amp")
    of '^':
      special("roof")
    of '!':
      special("emark")
    of '?':
      special("qmark")
    of '*':
      special("star")
    of '+':
      special("plus")
    of '-':
      special("minus")
    of '/':
      special("slash")
    of '\\':
      special("backslash")
    of '=':
      special("eq")
    of '<':
      special("lt")
    of '>':
      special("gt")
    of '~':
      special("tilde")
    of ':':
      special("colon")
    of '.':
      special("dot")
    of '@':
      special("at")
    of '|':
      special("bar")
    else:
      result.add 'X'
      result.add toHex(ord(character), 2)
      requiresUnderscore = true
  if requiresUnderscore:
    result.add '_'

func cSymbolPrefix(symbol: string): string =
  let overload = symbol.semanticOverload
  if overload.len > 0:
    result = symbol.semanticName.mangleCName & "_u" & overload & "__"

func bifModuleSuffix(path: string): string =
  let name = path.extractFilename
  const suffix = ".s.bif"
  if name.endsWith(suffix):
    result = name[0 ..< name.len - suffix.len]

proc normalizedAbsolutePath(path: string): string =
  if fileExists(path) or dirExists(path):
    result = expandFilename(path)
  else:
    result = absolutePath(path)
  normalizePath(result)

proc pathIsWithin(path, root: string): bool =
  let relative = relativePath(path, root)
  result =
    not relative.isAbsolute and relative != ".." and
    not relative.startsWith(".." & $DirSep)

proc readModuleSource(module: var BifModule): string =
  var cursor = module.buf.beginRead()
  let sourceNode = cursor.findDescendantTag("modulesrc")
  let source = sourceNode.findChildKind(StrLit)
  if not source.cursorIsNil:
    result = source.strVal
  cursor.endRead()

proc findSemanticBifPath*(nimcacheDir, sourcePath: string): string =
  ## Finds the semantic BIF whose module source matches ``sourcePath``.
  let expected = normalizedAbsolutePath(sourcePath)
  for path in walkFiles(nimcacheDir / "*.s.bif"):
    var module = bif.load(path)
    let candidate = module.readModuleSource()
    if candidate.len > 0 and normalizedAbsolutePath(candidate) == expected:
      return path
  fail("semantic BIF not found for: " & sourcePath)

func libraryStem(path: string): string =
  let name = path.extractFilename
  for marker in [".dylib", ".so", ".dll"]:
    let position = name.find(marker)
    if position > 0 and (
      position + marker.len == name.len or
      marker == ".so" and name[position + marker.len] == '.'
    ):
      return name[0 ..< position]
  result = name.splitFile.name
  if result.len == 0:
    result = name

func symbolFragment(value: string): string =
  var previousWasUnderscore = false
  for character in value:
    if character in {'A' .. 'Z', 'a' .. 'z', '0' .. '9'}:
      result.add character
      previousWasUnderscore = false
    elif not previousWasUnderscore:
      result.add '_'
      previousWasUnderscore = true
  while result.len > 0 and result[^1] == '_':
    result.setLen(result.len - 1)
  if result.len == 0:
    result = "library"
  elif result[0] in {'0' .. '9'}:
    result = "lib_" & result

proc nativeInitSymbol*(libraryName, bifPath: string): string =
  ## Returns the exported alias used to initialize one native Nim library.
  let identity = bifModuleSuffix(bifPath)
  if identity.len == 0:
    fail("semantic BIF has an invalid filename: " & bifPath)
  result =
    libraryStem(libraryName).symbolFragment & "_NimMain_" & identity.symbolFragment

proc isRoutineDeclaration(declaration: Cursor): bool =
  if declaration.kind != TagLit:
    return false
  var children = declaration.childCursor()
  while children.hasMore:
    if children.kind == TagLit and children.tagName in routineKinds:
      var marker = children.childCursor()
      if not marker.hasMore:
        result = true
      elif not children.findChildTag("genericparams").cursorIsNil:
        # Generic declarations have no runtime symbol until instantiated.
        return false
    children.skip

proc isSourceRoutineDeclaration(declaration: Cursor): bool =
  if not declaration.isRoutineDeclaration:
    return false
  var children = declaration.childCursor()
  while children.hasMore:
    if children.kind == TagLit and children.tagName in routineKinds and
        not children.findChildTag("ht").cursorIsNil:
      return true
    children.skip

proc methodDispatcherSymbol(declaration: Cursor): string =
  var children = declaration.childCursor()
  while children.hasMore:
    if children.kind == TagLit and children.tagName == "method" and
        not children.findChildTag("ht").cursorIsNil:
      var parts = children.childCursor()
      while parts.hasMore:
        if parts.kind == TagLit and parts.tagName == "sd" and
            not parts.findChildTag("method").cursorIsNil:
          let name = parts.findChildKind(SymbolDef)
          if not name.cursorIsNil:
            return name.symName
        parts.skip
      # Overrides refer to the existing dispatcher instead of defining it.
      let dispatcher = children.findLastChildKind(Symbol)
      if not dispatcher.cursorIsNil:
        return dispatcher.symName
    children.skip

func backendSymbol(symbol: NativeExportSymbol): string =
  if symbol.backendNifSymbol.len > 0:
    symbol.backendNifSymbol
  else:
    symbol.nifSymbol

func thunkKey(symbol: NativeExportSymbol): string =
  if symbol.genericOrigin.len > 0:
    "generic:" & symbol.genericOrigin & "\x1f" & symbol.genericArgumentSelectors.join("\x1f")
  else:
    symbol.nifSymbol

proc declarationTypeSymbol(declaration: Cursor): string =
  let typeDesc = declaration.findChildTag("td")
  if not typeDesc.cursorIsNil:
    let typeId = typeDesc.findChildKind(SymbolDef)
    if not typeId.cursorIsNil:
      result = typeId.symName

func symbolBase(symbol: string): string =
  let separator = symbol.find('.')
  if separator < 0:
    result = symbol
  else:
    result = symbol[0 ..< separator]

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

proc firstParameterType(declaration: Cursor): string =
  let formals = declaration.findDescendantTag("formalparams")
  if formals.cursorIsNil:
    return
  var children = formals.childCursor()
  while children.hasMore:
    if children.kind == TagLit and children.tagName == "sd" and
        not children.findChildTag("param").cursorIsNil:
      let typeDesc = children.findChildTag("td")
      if not typeDesc.cursorIsNil:
        let typeId = typeDesc.findChildKind(SymbolDef)
        if not typeId.cursorIsNil:
          result = typeId.symName
          if result.startsWith("`t23."):
            let element = typeDesc.findLastChildKind(Symbol)
            if not element.cursorIsNil:
              result = element.symName
          return
      let typeSymbol = children.findChildKind(Symbol)
      if not typeSymbol.cursorIsNil:
        return typeSymbol.symName
    children.skip

proc activeSemanticModules(nimcacheDir, mainSource: string): HashSet[string] =
  if mainSource.len == 0: return
  var pending = @[bifModuleSuffix(findSemanticBifPath(nimcacheDir, mainSource))]
  while pending.len > 0:
    let identity = pending.pop()
    if identity in result: continue
    result.incl identity
    var module = bif.load(nimcacheDir / (identity & ".s.bif"))
    var root = module.buf.beginRead()
    var child = root.childCursor()
    while child.hasMore:
      if child.tagIs("import"):
        let imported = child.findChildKind(StrLit)
        if not imported.cursorIsNil: pending.add imported.strVal
      child.skip
    root.endRead()

proc nativeOpaqueExports*(
    nimcacheDir, sourceRoot, mainSource: string, config: NativeExportConfig
): seq[NativeOpaqueExport] =
  let active = activeSemanticModules(nimcacheDir, mainSource)
  let root = sourceRoot.normalizedAbsolutePath
  for selector in config.opaqueTypes:
    var matches: seq[NativeOpaqueExport]
    for path in walkFiles(nimcacheDir / "*.s.bif"):
      let identity = bifModuleSuffix(path)
      if active.len > 0 and identity notin active:
        continue
      var module = bif.load(path)
      let source = module.readModuleSource().normalizedAbsolutePath
      for symbol, visibility, declaration in module.declarations:
        if visibility == ivExported and semanticModule(symbol) == identity and
            not declaration.findChildTag("type").cursorIsNil and
            includeProc(selector.name, selector.source).matches(
              relativePath(source, root), symbol.semanticName
            ):
          matches.add NativeOpaqueExport(
            sourcePath: source,
            typeName: selector.name,
            nifSymbol: symbol,
            hookPrefix: "binny_opaque_" & symbol.mangleCName,
          )
    if matches.len != 1:
      fail(
        "native opaque type " & selector.name &
          " requires exactly one source-owned match"
      )
    for previous in result:
      if previous.nifSymbol == matches[0].nifSymbol:
        fail("duplicate native opaque type: " & selector.name)
    result.add matches[0]

proc applyExportConfig(
    symbols: openArray[NativeExportSymbol],
    sourceRoot: string,
    exportConfig: NativeExportConfig,
    resolvedGenerics = true,
): seq[NativeExportSymbol] =
  exportConfig.validateNativeExportConfig()
  if exportConfig.includeProcs.len == 0 and exportConfig.excludeProcs.len == 0:
    return @symbols

  let root = normalizedAbsolutePath(sourceRoot)
  var includedMatches = newSeq[bool](exportConfig.includeProcs.len)
  var matched = newSeq[bool](exportConfig.excludeProcs.len)
  for symbol in symbols:
    let
      source = relativePath(symbol.sourcePath, root).replace('\\', '/')
      name = semanticName(symbol.nifSymbol)
    var included = exportConfig.includeProcs.len == 0
    for index, selector in exportConfig.includeProcs:
      if selector.matches(source, name) and (selector.typeArgs.len == 0 or
          selector.typeArgs == symbol.genericArgumentSelectors or
          not resolvedGenerics and symbol.genericOrigin.len > 0):
        includedMatches[index] = true
        included = true
    var excluded = false
    for index, selector in exportConfig.excludeProcs:
      if selector.matches(source, name) and (selector.typeArgs.len == 0 or
          resolvedGenerics and selector.typeArgs == symbol.genericArgumentSelectors):
        matched[index] = true
        excluded = true
    if included and not excluded:
      result.add symbol

  if exportConfig.requireMatches and resolvedGenerics:
    var missing: seq[string]
    for index, selector in exportConfig.includeProcs:
      if not includedMatches[index]:
        let source = if selector.source.len == 0: "*" else: selector.source
        missing.add "include " & source & ":" & selector.name
    for index, selector in exportConfig.excludeProcs:
      if not matched[index]:
        let source = if selector.source.len == 0: "*" else: selector.source
        missing.add "exclude " & source & ":" & selector.name
    if missing.len > 0:
      fail(
        "native export selectors matched no public procedures:\n  " &
          missing.join("\n  ")
      )

proc publicRoutineSymbols*(
    nimcacheDir, sourceRoot: string, exportConfig = NativeExportConfig(), mainSource = ""
): seq[NativeExportSymbol] =
  ## Returns public, runtime routine declarations owned by application modules.
  ##
  ## ``sourceRoot`` bounds the application: public routines from the compiler
  ## and external dependencies in the same nimcache are deliberately excluded.
  ## ``mainSource`` bounds concrete generic instances to its semantic import
  ## graph. Prepared C builds retain this source in their build state.
  let root = normalizedAbsolutePath(sourceRoot)
  var paths: seq[string]
  for path in walkFiles(nimcacheDir / "*.s.bif"):
    paths.add path
  paths.sort()

  var evidence: GenericEvidence
  var instances: seq[tuple[symbol: string, origin: string, declaration: Cursor]]
  var generic_origins: Table[string, string]
  let state_path = nimcacheDir / "binny_native_build.json"
  let recorded_source = if fileExists(state_path):
                          parseFile(state_path).getOrDefault("mainSource").getStr
                        else: ""
  let active_modules = activeSemanticModules(nimcacheDir,
    if mainSource.len > 0: mainSource else: recorded_source)

  for path in paths:
    var module = bif.load(path)
    let source = module.readModuleSource()
    if source.len == 0:
      continue
    let absoluteSource = normalizedAbsolutePath(source)
    if not pathIsWithin(absoluteSource, root) and exportConfig.includeProcs.len == 0:
      continue

    let moduleSuffix = bifModuleSuffix(path)
    for name, visibility, declaration in module.declarations:
      let origin = declaration.instantiatedFrom
      if origin.len > 0 and declaration.isRoutineDeclaration and
          (active_modules.len == 0 or moduleSuffix in active_modules):
        instances.add (name, origin, declaration)
      if visibility == ivExported and semanticModule(name) == moduleSuffix:
        var children = declaration.childCursor()
        while children.hasMore:
          if children.kind == TagLit and children.tagName in routineKinds and
              not children.findChildTag("genericparams").cursorIsNil:
            generic_origins[name] = absoluteSource
          children.skip
      if visibility == ivExported and semanticModule(name) == moduleSuffix and
          declaration.isRoutineDeclaration:
        var inlineRoutine = false
        let typeDesc = declaration.findChildTag("td")
        if not typeDesc.cursorIsNil:
          var typeParts = typeDesc.childCursor()
          while typeParts.hasMore:
            if typeParts.kind == Ident and typeParts.strVal == "inline":
              inlineRoutine = true
            typeParts.skip
        var children = declaration.childCursor()
        while children.hasMore:
          if children.kind == TagLit and children.tagName in routineKinds and
              not children.findChildTag("ht").cursorIsNil:
            let pragmas = children.findChildTag("pragma")
            inlineRoutine = inlineRoutine or
              (not pragmas.cursorIsNil and pragmas.hasDescendantIdent("inline"))
          children.skip
        let position = declaration.rawLineInfo
        result.add NativeExportSymbol(
          sourcePath: absoluteSource, nifSymbol: name,
          backendNifSymbol: methodDispatcherSymbol(declaration),
          inlineRoutine: inlineRoutine,
          iteratorRoutine: not declaration.findChildTag("iterator").cursorIsNil,
          sourceLine: int(position.line), sourceColumn: int(position.col),
        )
  var generic_instances: seq[NativeExportSymbol]
  for instance in instances:
    if instance.origin in generic_origins:
      let position = instance.declaration.rawLineInfo
      generic_instances.add NativeExportSymbol(
        sourcePath: generic_origins[instance.origin], nifSymbol: instance.symbol,
        genericOrigin: instance.origin, sourceLine: int(position.line),
        sourceColumn: int(position.col),
        iteratorRoutine: not instance.declaration.findChildTag("iterator").cursorIsNil,
      )
  if generic_instances.len > 0:
    # Determine selected origins before resolving types from dependency BIFs.
    let selected = applyExportConfig(result & generic_instances, sourceRoot, exportConfig,
      resolvedGenerics = false)
    var selected_ids = initHashSet[string]()
    for routine in selected:
      if routine.genericOrigin.len > 0: selected_ids.incl routine.nifSymbol
    if selected_ids.len > 0:
      for path in paths:
        var module = bif.load(path)
        evidence.addModule(module, bifModuleSuffix(path), module.readModuleSource())
      var seen = initHashSet[string]()
      for instance in instances:
        if instance.symbol notin selected_ids: continue
        var routine: NativeExportSymbol
        for candidate in generic_instances:
          if candidate.nifSymbol == instance.symbol: routine = candidate
        routine.genericArguments = evidence.specializationArguments(
          evidence.originDeclaration(instance.origin), instance.declaration, routine.genericSources)
        routine.genericSignature = routine.nifSymbol.semanticName &
          evidence.signatureKey(instance.declaration)
        for argument in routine.genericArguments:
          var selector = argument.replace("`", "")
          for identity, source in evidence.sources:
            selector = selector.replace("binnyGenericModule_" & identity & ".",
              relativePath(normalizedAbsolutePath(source), root).replace('\\', '/') & ":")
          routine.genericArgumentSelectors.add selector
        let key = routine.genericOrigin & "\x1f" & routine.genericArguments.join("\x1f")
        if key notin seen:
          seen.incl key
          result.add routine
  result = applyExportConfig(result, sourceRoot, exportConfig)
  var signatures: Table[string, string]
  for routine in result:
    if routine.genericOrigin.len == 0: continue
    if routine.genericSignature in signatures:
      fail("concrete generic exports have indistinguishable call signatures: " &
        signatures[routine.genericSignature] & " and " & routine.nifSymbol &
        "; select the specialization with typeArgs")
    signatures[routine.genericSignature] = routine.nifSymbol

proc nativeHookSymbols*(nimcacheDir, sourceRoot: string): seq[NativeHookSymbol] =
  ## Returns custom and forbidden ownership hooks belonging to public app types.
  let root = normalizedAbsolutePath(sourceRoot)
  var paths: seq[string]
  for path in walkFiles(nimcacheDir / "*.s.bif"):
    paths.add path
  paths.sort()

  for path in paths:
    var module = bif.load(path)
    let source = module.readModuleSource()
    if source.len == 0:
      continue
    let absoluteSource = normalizedAbsolutePath(source)
    if not pathIsWithin(absoluteSource, root):
      continue

    let moduleSuffix = bifModuleSuffix(path)
    var publicTypes: Table[string, string]
    for name, visibility, declaration in module.declarations:
      if visibility == ivExported and semanticModule(name) == moduleSuffix and
          not declaration.findChildTag("type").cursorIsNil:
        let typeSymbol = declaration.declarationTypeSymbol()
        if typeSymbol.len > 0:
          publicTypes[typeSymbol] = name.semanticName

    for name, visibility, declaration in module.declarations:
      if visibility == ivHidden and semanticModule(name) == moduleSuffix and
          name.symbolBase in hookKinds and declaration.isSourceRoutineDeclaration:
        let typeSymbol = declaration.firstParameterType()
        if typeSymbol in publicTypes:
          result.add NativeHookSymbol(
            sourcePath: absoluteSource,
            typeSymbol: typeSymbol,
            typeName: publicTypes[typeSymbol],
            hookKind: name.symbolBase,
            nifSymbol: name,
            forbidden: declaration.hasDescendantIdent("error"),
          )

proc readCDefinitions(path: string): seq[CDefinition] =
  var artifact = nifcoreparse.parseFromFile(path)
  var cursor = artifact.beginRead()
  if cursor.kind != TagLit or cursor.tagName != "stmts":
    cursor.endRead()
    fail("invalid C NIF artifact: " & path)

  var children = cursor.childCursor()
  while children.hasMore:
    if children.kind == TagLit and children.tagName == "cdef":
      var fields = children.childCursor()
      var definition: CDefinition
      if fields.hasMore and fields.kind == SymbolDef:
        definition.cSymbol = fields.symName
        fields.skip
      if fields.hasMore:
        case fields.kind
        of Ident:
          definition.flags = fields.strVal
        of Symbol:
          definition.flags = fields.symName
        of DotToken:
          discard
        else:
          discard
        fields.skip
      if fields.hasMore and fields.kind == StrLit:
        definition.nifSymbol = fields.strVal
      if definition.cSymbol.len > 0 and definition.nifSymbol.len > 0:
        result.add definition
    children.skip
  cursor.endRead()

func withRootFlag(flags: string): string =
  if 'x' in flags:
    return flags
  result = flags & "x"

proc replaceDefinitionFlags(content: var string, definition: CDefinition): bool =
  let
    oldFlags = if definition.flags.len == 0: "." else: definition.flags
    newFlags = definition.flags.withRootFlag
    oldPrefix = "(cdef :" & definition.cSymbol & " " & oldFlags & " "
    newPrefix = "(cdef :" & definition.cSymbol & " " & newFlags & " "
    position = content.find(oldPrefix)
  if position < 0:
    fail("C NIF definition changed while rooting " & definition.cSymbol)
  if content.find(oldPrefix, position + oldPrefix.len) >= 0:
    fail("duplicate C NIF definition in one artifact: " & definition.cSymbol)
  content[position ..< position + oldPrefix.len] = newPrefix
  result = true

proc resolveIncrementalNativeSymbols(
    nimcacheDir: string, symbols: openArray[NativeExportSymbol]
): seq[NativeExportSymbol] =
  ## Matches semantic routines to their exact incremental-backend C names.
  result = @symbols
  var indexes = initTable[string, seq[int]]()
  for index, symbol in result:
    indexes.mgetOrPut(symbol.backendSymbol, @[]).add index

  var matched = initHashSet[string]()
  for path in walkFiles(nimcacheDir / "*.c.nif"):
    for definition in readCDefinitions(path):
      if definition.nifSymbol in indexes:
        for index in indexes[definition.nifSymbol]:
          if result[index].cSymbol.len == 0:
            result[index].cSymbol = definition.cSymbol
          elif result[index].cSymbol != definition.cSymbol:
            fail(
              "one semantic routine has multiple backend names: " & definition.nifSymbol
            )
        matched.incl definition.nifSymbol

  var missing: seq[string]
  for symbol in result:
    if symbol.backendSymbol notin matched:
      missing.add symbol.nifSymbol
  if missing.len > 0:
    missing.sort()
    fail("native routines have no backend definitions:\n  " & missing.join("\n  "))

func isCIdentifierCharacter(character: char): bool =
  character in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}

func cTokenPrefix(token: string): string =
  var marker = token.find("_u")
  while marker >= 0:
    var position = marker + 2
    let digitStart = position
    while position < token.len and token[position] in {'0' .. '9'}:
      inc position
    if position > digitStart and position + 1 < token.len and token[position] == '_' and
        token[position + 1] == '_':
      return token[0 .. position + 1]
    marker = token.find("_u", marker + 2)

func mangleCModuleSuffix(path: string): string =
  ## Mirrors Nim's uniqueModuleName encoding used as C symbol suffixes.
  let modulePath =
    if path.endsWith(".nim"):
      path[0 ..< path.len - ".nim".len]
    else:
      path
  for character in modulePath:
    case character
    of 'a' .. 'z', '0' .. '9':
      result.add character
    of '/', '\\':
      result.add 'Z'
    of '.':
      result.add 'O'
    else:
      result.addInt ord(character)

proc sourceCModuleSuffixes(sourcePath: string): seq[string] =
  ## Returns path suffixes that Nim may use when naming ``sourcePath``.
  ##
  ## The compiler makes the path relative to either the project, a search path,
  ## or a package root.  We do not have that compiler configuration here, but
  ## every such relative path ends in a suffix of the absolute source path.
  let components = normalizedAbsolutePath(sourcePath).replace('\\', '/').split('/')
  if components.len == 0:
    return
  let last = components.high
  for first in 0 .. last:
    let suffix = mangleCModuleSuffix(components[first .. last].join("/"))
    if suffix.len > 0 and suffix notin result:
      result.add suffix

proc sourceOwnedCBackendSymbols(
    candidates: HashSet[string], prefix, sourcePath, projectPath, libPath: string
): HashSet[string] =
  ## A prepared build has the exact C project path, not a guessed suffix length.
  let base = if libPath.len > 0 and pathIsWithin(sourcePath, libPath): libPath
             else: projectPath
  let suffixes =
    if base.len > 0:
      @[mangleCModuleSuffix(relativePath(sourcePath, base).replace('\\', '/'))]
    else:
      sourceCModuleSuffixes(sourcePath)
  for candidate in candidates:
    if candidate.len > prefix.len and candidate[prefix.len ..^ 1] in suffixes:
      result.incl candidate

func cBuildStatePath(nimcacheDir: string): string =
  nimcacheDir / "binny_native_build.json"

proc cBuildState(nimcacheDir: string): JsonNode =
  let path = cBuildStatePath(nimcacheDir)
  result = if fileExists(path): parseFile(path) else: newJObject()

proc findCBuildManifest(nimcacheDir, explicitPath: string): string =
  if explicitPath.len > 0:
    if not fileExists(explicitPath):
      fail("C build manifest is missing: " & explicitPath)
    return normalizedAbsolutePath(explicitPath)
  let state = cBuildState(nimcacheDir)
  if state.hasKey("manifest"):
    return findCBuildManifest(nimcacheDir, state["manifest"].getStr)
  var manifests: seq[string]
  for path in walkFiles(nimcacheDir / "*.json"):
    let description = parseFile(path)
    if description.kind == JObject and description.hasKey("compile") and
        description.hasKey("link") and description.hasKey("outputFile"):
      manifests.add path
  if manifests.len != 1:
    fail("expected one active C build manifest; pass cBuildManifest to prepareNativeRoutines")
  result = normalizedAbsolutePath(manifests[0])

proc activeCSources(nimcacheDir: string): seq[string] =
  let path = findCBuildManifest(nimcacheDir, "")
  let description = parseFile(path)
  if not description.hasKey("link") or description["link"].kind != JArray:
    fail("C build manifest has no link object list: " & path)
  let base = description.getOrDefault("currentDir").getStr(path.parentDir)
  for node in description["link"]:
    let objectPath = node.getStr
    let extension = objectPath.splitFile.ext
    if extension in [".o", ".obj"]:
      let source = objectPath[0 ..< objectPath.len - extension.len]
      let absoluteSource = if source.isAbsolute: source else: base / source
      if absoluteSource.endsWith(".c") and fileExists(absoluteSource) and
          absoluteSource notin result:
        result.add absoluteSource

proc compilerCLibPath(manifestPath: string): string =
  let description = parseFile(manifestPath)
  for entry in description["compile"]:
    let arguments = parseCmdLine(entry[1].getStr)
    for index, argument in arguments:
      let directory =
        if argument in ["-I", "/I"] and index + 1 < arguments.len: arguments[index + 1]
        elif argument.startsWith("-I") or argument.startsWith("/I"): argument[2 ..^ 1]
        else: ""
      if directory.len > 0 and fileExists(directory / "nimbase.h"):
        let path = normalizedAbsolutePath(directory)
        if result.len > 0 and result != path:
          fail("C build manifest uses multiple Nim library headers: " & manifestPath)
        result = path

proc cTokens(content: string): seq[string] =
  var position = 0
  while position < content.len:
    let character = content[position]
    if character in Whitespace:
      inc position
    elif character == '#' or (character == '/' and position + 1 < content.len and
        content[position + 1] == '/'):
      while position < content.len and content[position] != '\n':
        if content[position] == '\\' and position + 1 < content.len:
          position += 2
        else:
          inc position
    elif character == '/' and position + 1 < content.len and content[position + 1] == '*':
      let ending = content.find("*/", position + 2)
      position = if ending < 0: content.len else: ending + 2
    elif character in {'"', '\''}:
      inc position
      while position < content.len and content[position] != character:
        position += (if content[position] == '\\': 2 else: 1)
      if position < content.len:
        inc position
      result.add "literal"
    elif character.isCIdentifierCharacter:
      let start = position
      while position < content.len and content[position].isCIdentifierCharacter:
        inc position
      result.add content[start ..< position]
    else:
      result.add $character
      inc position

proc cFunctionDefinitions(path: string): seq[string] =
  let tokens = cTokens(readFile(path))
  var depth = 0
  for index, token in tokens:
    if depth == 0 and (
      token.cTokenPrefix.len > 0 or token.startsWith("binny_inline_") or
      token.startsWith("binny_generic_") or token.startsWith("binny_opaque_") or
      token.startsWith("binny_iterator_")
    ):
      var position = index + 1
      # Nim's N_NIMCALL/N_INLINE macros place the name inside their parentheses.
      if position < tokens.len and tokens[position] == ")":
        inc position
      if position < tokens.len and tokens[position] == "(":
        var parentheses = 1
        inc position
        while position < tokens.len and parentheses > 0:
          if tokens[position] == "(": inc parentheses
          elif tokens[position] == ")": dec parentheses
          inc position
        if position < tokens.len and tokens[position] == "{":
          result.add token
    if token == "{": inc depth
    elif token == "}": dec depth

proc cBackendSymbols(nimcacheDir: string): HashSet[string] =
  for path in activeCSources(nimcacheDir):
    for definition in cFunctionDefinitions(path):
      result.incl definition

proc resolveCNativeSymbols(
    nimcacheDir: string, symbols: openArray[NativeExportSymbol]
): seq[NativeExportSymbol] =
  result = @symbols
  var moduleIndexes: Table[string, seq[int]]
  var candidates = newSeq[HashSet[string]](result.len)
  var missing: seq[string]
  let backendSymbols = cBackendSymbols(nimcacheDir)
  let state = cBuildState(nimcacheDir)
  let projectPath = state.getOrDefault("projectPath").getStr
  let libPath = state.getOrDefault("libPath").getStr
  let thunks = state.getOrDefault("thunks")
  var backendSources: Table[string, string]
  for index, symbol in result:
    if thunks != nil and thunks.hasKey(symbol.thunkKey):
      let thunk = thunks[symbol.thunkKey].getStr
      if thunk notin backendSymbols:
        fail("selected routine has no C forwarding thunk definition: " & symbol.nifSymbol)
      result[index].cSymbol = thunk
      continue
    let backendModule = symbol.backendSymbol.semanticModule
    var backendSource = symbol.sourcePath
    if backendModule != symbol.nifSymbol.semanticModule or symbol.genericOrigin.len > 0:
      if backendModule notin backendSources:
        var module = bif.load(nimcacheDir / (backendModule & ".s.bif"))
        backendSources[backendModule] = module.readModuleSource()
      backendSource = backendSources[backendModule]
    let prefix = symbol.backendSymbol.cSymbolPrefix
    if prefix.len == 0:
      missing.add symbol.nifSymbol
    else:
      for definition in backendSymbols:
        if definition.cTokenPrefix == prefix:
          candidates[index].incl definition
      candidates[index] = sourceOwnedCBackendSymbols(
        candidates[index], prefix, backendSource, projectPath, libPath
      )
      if candidates[index].len == 0:
        missing.add symbol.nifSymbol
    moduleIndexes.mgetOrPut(backendModule, @[]).add index
  if missing.len > 0:
    missing.sort()
    fail("native routines have no C backend definitions:\n  " & missing.join("\n  "))

  for module, indexes in moduleIndexes:
    var commonSuffixes: HashSet[string]
    var first = true
    for index in indexes:
      let prefix = result[index].backendSymbol.cSymbolPrefix
      var suffixes: HashSet[string]
      for candidate in candidates[index]:
        suffixes.incl candidate[prefix.len ..^ 1]
      if first:
        commonSuffixes = suffixes
        first = false
      else:
        commonSuffixes = commonSuffixes * suffixes
    if commonSuffixes.len != 1:
      fail("cannot determine one C backend module suffix for " & module)
    let suffix = commonSuffixes.pop()
    for index in indexes:
      let candidate = result[index].backendSymbol.cSymbolPrefix & suffix
      if candidate notin candidates[index]:
        fail("C backend definition mismatch for " & result[index].nifSymbol)
      result[index].cSymbol = candidate

proc hasIncrementalCArtifacts*(nimcacheDir: string): bool =
  for _ in walkFiles(nimcacheDir / "*.c.nif"):
    return true

proc resolveNativeSymbols*(
    nimcacheDir: string, symbols: openArray[NativeExportSymbol]
): seq[NativeExportSymbol] =
  ## Matches semantic routines to exact names from either compiler C backend.
  if nimcacheDir.hasIncrementalCArtifacts and not fileExists(cBuildStatePath(nimcacheDir)):
    result = resolveIncrementalNativeSymbols(nimcacheDir, symbols)
  else:
    result = resolveCNativeSymbols(nimcacheDir, symbols)

proc resolveNativeHooks*(
    nimcacheDir: string, hooks: openArray[NativeHookSymbol]
): seq[NativeHookSymbol] =
  ## Adds exact backend names to custom hooks; forbidden hooks have no definition.
  result = @hooks
  var unresolved: seq[NativeExportSymbol]
  var indexes: seq[int]
  for index, hook in result:
    if not hook.forbidden:
      indexes.add index
      unresolved.add NativeExportSymbol(
        sourcePath: hook.sourcePath, nifSymbol: hook.nifSymbol
      )
  let resolved = resolveNativeSymbols(nimcacheDir, unresolved)
  for index, symbol in resolved:
    result[indexes[index]].cSymbol = symbol.cSymbol

proc nativeCRootSourcePath*(nimcacheDir: string): string =
  ## Returns the generated reachability-root module used by ``nim c`` builds.
  nimcacheDir / "binny_native_root.nim"

func nimStringLiteral(value: string): string =
  "\"" & value.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

func nimQuotedIdentifier(value: string): string =
  "`" & value.replace("`", "") & "`"

proc writeCBackendRoot(
    outputPath, mainSource: string,
    routines: openArray[NativeExportSymbol],
    hooks: openArray[NativeHookSymbol],
    opaqueExports: openArray[NativeOpaqueExport],
): JsonNode =
  result = newJObject()
  for routine in routines:
    if routine.iteratorRoutine or routine.inlineRoutine or routine.genericOrigin.len > 0:
      let prefix = if routine.iteratorRoutine: "binny_iterator_"
                   elif routine.genericOrigin.len > 0: "binny_generic_" else: "binny_inline_"
      result[routine.thunkKey] = % (prefix & routine.nifSymbol.mangleCName)
  var routineNamesBySource: Table[string, seq[string]]
  # Import the producer even when the selected API consists only of dependencies.
  var sources = @[normalizedAbsolutePath(mainSource)]
  for routine in routines:
    let source = normalizedAbsolutePath(routine.sourcePath)
    if source notin sources:
      sources.add source
    let name = routine.nifSymbol.semanticName
    if name notin routineNamesBySource.mgetOrPut(source, @[]):
      routineNamesBySource[source].add name
  for hook in hooks:
    let source = normalizedAbsolutePath(hook.sourcePath)
    if source notin sources:
      sources.add source
  for opaque in opaqueExports:
    if opaque.sourcePath notin sources:
      sources.add opaque.sourcePath
  sources.sort()

  var aliases: Table[string, string]
  var content = "## Generated by Binny to keep public native routines reachable.\n\n"
  content.add "import std/macros\n"
  if result.len > 0:
    content.add """

proc binnyInlineThunk(symbol: NimNode, exportName: string): NimNode {.compileTime.} =
  let implementation = symbol.getImpl
  let parameters = symbol.getTypeInst[0].copyNimTree
  var invocation = newCall(symbol)
  for index in 1..<parameters.len:
    let parameter = parameters[index]
    for nameIndex in 0..<parameter.len - 2:
      let argument = genSym(nskParam, "argument" & $(invocation.len - 1))
      parameter[nameIndex] = argument
      invocation.add argument
    parameter[^1] = newEmptyNode()
  var pragmas = newTree(nnkPragma)
  for pragma in implementation[4]:
    let name = if pragma.kind == nnkExprColonExpr: pragma[0] else: pragma
    if name.kind notin {nnkIdent, nnkSym} or $name notin [
      "inline", "exportc", "extern", "dynlib", "importc", "header", "noinline", "used"
    ]:
      pragmas.add pragma.copyNimTree
  pragmas.add ident("noinline")
  pragmas.add ident("used")
  pragmas.add newColonExpr(ident("exportc"), newLit(exportName))
  let body = if parameters[0].kind == nnkEmpty: invocation
             else: newTree(nnkReturnStmt, invocation)
  result = newTree(nnkProcDef, ident(exportName), newEmptyNode(), newEmptyNode(),
    parameters, pragmas, newEmptyNode(), newStmtList(body))

proc binnyIteratorFactory(symbol: NimNode, exportName: string): NimNode {.compileTime.} =
  let signature = symbol.getTypeInst
  let parameters = signature[0].copyNimTree
  var closureIterator = false
  for pragma in signature[1]:
    if pragma.eqIdent("closure"):
      closureIterator = true
  var invocation = newCall(symbol)
  for index in 1..<parameters.len:
    let parameter = parameters[index]
    for nameIndex in 0..<parameter.len - 2:
      let argument = genSym(nskParam, "argument" & $(invocation.len - 1))
      parameter[nameIndex] = argument
      invocation.add argument
    parameter[^1] = newEmptyNode()
  let stop = genSym(nskParam, "binnyStop")
  if not closureIterator:
    parameters.add newIdentDefs(stop, bindSym("bool"))
  let iteratorType = newTree(nnkIteratorTy, parameters.copyNimTree,
    newTree(nnkPragma, ident("closure")))
  let item = genSym(nskForVar, "item")
  let resume = genSym(nskIterator, "resume")
  let body = newTree(nnkForStmt, item, invocation,
    newStmtList(newTree(nnkYieldStmt, item),
      newTree(nnkIfStmt, newTree(nnkElifBranch, stop,
        newStmtList(newTree(nnkBreakStmt, newEmptyNode()))))))
  let iteratorDef = newTree(nnkIteratorDef, resume, newEmptyNode(), newEmptyNode(),
    parameters, newTree(nnkPragma, ident("closure")), newEmptyNode(), body)
  result = newTree(nnkProcDef, ident(exportName), newEmptyNode(), newEmptyNode(),
    newTree(nnkFormalParams, iteratorType),
    newTree(nnkPragma, ident("used"), ident("noinline"),
      newColonExpr(ident("exportc"), newLit(exportName))), newEmptyNode(),
    newStmtList(iteratorDef, newTree(nnkReturnStmt, resume)))
  if closureIterator:
    result[^1] = newStmtList(newTree(nnkReturnStmt, symbol))

"""
  for index, source in sources:
    let
      parts = source.splitFile
      modulePath = parts.dir / parts.name
      moduleAlias = "binnyRootModule" & $index
    aliases[source] = moduleAlias
    content.add "import " & modulePath.nimStringLiteral & " as " & moduleAlias & "\n"
    if source in routineNamesBySource:
      var names = routineNamesBySource[source]
      names.sort()
      content.add "from " & modulePath.nimStringLiteral & " import "
      for nameIndex, name in names:
        if nameIndex > 0:
          content.add ", "
        content.add name.nimQuotedIdentifier
      content.add "\n"

  if opaqueExports.len > 0:
    content.add "\nwhen defined(gcOrc) or not (defined(gcArc) or defined(gcAtomicArc)):\n"
    content.add "  {.error: \"Opaque native types require ARC/atomicARC; ORC tracing is not supported.\".}\n"
    content.add "when not defined(useMalloc):\n"
    content.add "  {.error: \"Opaque native types require -d:useMalloc.\".}\n"
  for opaque in opaqueExports:
    let qualified =
      aliases[opaque.sourcePath] & "." & opaque.typeName.nimQuotedIdentifier
    let storage = opaque.hookPrefix & "Storage"
    content.add "\nwhen " & qualified & " is ref:\n"
    content.add "  type " & storage & " = typeof(default(" & qualified & ")[])\n"
    content.add "else:\n  type " & storage & " = " & qualified & "\n"
    content.add "static:\n  doAssert sizeof(" & storage & ") >= 0\n"
    content.add "  doAssert alignof(" & storage & ") > 0\n"
    content.add "proc " & opaque.hookPrefix & "Size(): int {.used, exportc.} = sizeof(" &
      storage & ")\n"
    content.add "proc " & opaque.hookPrefix &
      "Alignment(): int {.used, exportc.} = alignof(" & storage & ")\n"
    content.add "proc " & opaque.hookPrefix &
      "Destroy(value: pointer) {.used, exportc.} =\n"
    content.add "  reset(cast[ptr " & storage & "](value)[])\n"
    content.add "proc " & opaque.hookPrefix &
      "Copy(dest, source: pointer) {.used, exportc.} =\n"
    content.add "  cast[ptr " & storage & "](dest)[] = cast[ptr " & storage &
      "](source)[]\n"

  var generic_sources = initHashSet[string]()
  for routine in routines:
    for source in routine.genericSources:
      if source notin generic_sources:
        generic_sources.incl source
        let identity = bifModuleSuffix(findSemanticBifPath(outputPath.parentDir, source))
        content.add "import " & (source.splitFile.dir / source.splitFile.name).nimStringLiteral &
          " as binnyGenericModule_" & identity & "\n"

  var rootedNames = initHashSet[string]()
  for routine in routines:
    let
      source = normalizedAbsolutePath(routine.sourcePath)
      name = routine.nifSymbol.semanticName
      key = source & "\x1f" & name
    if key notin rootedNames:
      rootedNames.incl key
      let keepMacro = "binnyKeepRoutine" & $rootedNames.len
      content.add "\nmacro " & keepMacro & "(): untyped =\n"
      content.add "  let symbols = bindSym(" & name.nimStringLiteral & ", brForceOpen)\n"
      content.add "  result = newStmtList()\n"
      content.add "  for symbol in symbols:\n"
      content.add "    let implementation = symbol.getImpl\n"
      content.add "    if implementation.lineInfoObj.filename == " &
        source.nimStringLiteral & " and\n"
      content.add "        implementation.kind in {nnkProcDef, nnkFuncDef, " &
        "nnkMethodDef, nnkConverterDef} and\n"
      content.add "        implementation[2].kind == nnkEmpty:\n"
      content.add "      result.add newLetStmt(genSym(nskLet, " &
        "\"binnyRoot\"), symbol)\n"
      content.add "\n" & keepMacro & "()\n"

  for index, routine in routines:
    if routine.iteratorRoutine or routine.inlineRoutine or routine.genericOrigin.len > 0:
      let
        source = normalizedAbsolutePath(routine.sourcePath)
        name = routine.nifSymbol.semanticName
        keepMacro = "binnyExportInline" & $index
        exportName = result[routine.thunkKey].getStr
        thunk_builder = if routine.iteratorRoutine: "binnyIteratorFactory" else: "binnyInlineThunk"
      content.add "\nmacro " & keepMacro & "(): untyped =\n"
      content.add "  result = newStmtList()\n"
      content.add "  for symbol in bindSym(" & name.nimStringLiteral & ", brForceOpen):\n"
      content.add "    let implementation = symbol.getImpl\n"
      content.add "    let position = implementation[0].lineInfoObj\n"
      content.add "    if position.filename == " & source.nimStringLiteral & " and\n"
      content.add "        position.line == " & $routine.sourceLine & " and\n"
      content.add "        position.column == " & $routine.sourceColumn & ":\n"
      if routine.genericOrigin.len > 0:
        let specialization_macro = "binnySpecialize" & $index
        # A typed macro receives the compiler's concrete routine symbol, so the
        # forwarding signature preserves ownership modifiers and overloads.
        content.add "      var specialization = newTree(nnkBracketExpr, symbol)\n"
        for argument in routine.genericArguments:
          content.add "      specialization.add parseExpr(" & argument.nimStringLiteral & ")\n"
        content.add "      result.add newCall(bindSym(" & specialization_macro.nimStringLiteral &
          "), specialization)\n"
      else:
        content.add "      result.add " & thunk_builder & "(symbol, " &
          exportName.nimStringLiteral & ")\n"
      content.add "  if result.len != 1:\n"
      content.add "    error(" & ("cannot identify native export " &
        routine.nifSymbol).nimStringLiteral & ")\n"
      if routine.genericOrigin.len > 0:
        let specialization_macro = "binnySpecialize" & $index
        # Place the typed helper before the macro that binds it.
        let insertion = content.rfind("\nmacro " & keepMacro)
        content.insert("\nmacro " & specialization_macro & "(symbol: typed): untyped =\n" &
          "  result = " & thunk_builder & "(symbol, " & exportName.nimStringLiteral & ")\n",
          insertion)
      content.add "\n" & keepMacro & "()\n"

  var typeHooks: Table[string, seq[NativeHookSymbol]]
  for hook in hooks:
    typeHooks.mgetOrPut(hook.typeSymbol, @[]).add hook
  var typeSymbols: seq[string]
  for typeSymbol in typeHooks.keys:
    typeSymbols.add typeSymbol
  typeSymbols.sort()
  if typeSymbols.len > 0:
    content.add "\nvar binnyHookSource {.volatile.}: pointer\n"
  for index, typeSymbol in typeSymbols:
    let hooksForType = typeHooks[typeSymbol]
    if hooksForType.len == 0:
      continue
    let
      source = normalizedAbsolutePath(hooksForType[0].sourcePath)
      qualifiedType =
        aliases[source] & "." & hooksForType[0].typeName.nimQuotedIdentifier
      keepProc = "binnyKeepHooks" & $index
    content.add "\nproc " & keepProc & "() =\n"
    content.add "  var source {.noinit.}: " & qualifiedType & "\n"
    content.add "  var destination {.noinit.}: " & qualifiedType & "\n"
    content.add "  copyMem(addr source, binnyHookSource, sizeof(source))\n"
    content.add "  copyMem(addr destination, binnyHookSource, sizeof(destination))\n"
    for hook in hooksForType:
      if hook.forbidden:
        continue
      case hook.hookKind
      of "=destroy":
        discard
      of "=copy":
        content.add "  destination = source\n"
      of "=sink":
        content.add "  destination = move(source)\n"
      of "=dup":
        content.add "  discard dup(source)\n"
      of "=wasMoved":
        content.add "  wasMoved(source)\n"
      else:
        fail(
          "nim c reachability roots do not support hook " & hook.hookKind &
            "; use nim ic for this producer"
        )
    content.add "  binnyHookSource = addr source\n"
    content.add "\nlet binnyHookRoot" & $index & " = " & keepProc & "\n"

  let outputDir = outputPath.parentDir
  if outputDir.len > 0:
    createDir(outputDir)
  if not fileExists(outputPath) or readFile(outputPath) != content:
    writeFile(outputPath, content)

proc rootPublicRoutines*(
    nimcacheDir, sourceRoot, mainSource: string, exportConfig = NativeExportConfig()
): seq[NativeExportSymbol] =
  ## Roots public app routines and ownership hooks required by public types.
  ##
  ## Run this after the first ``nim ic`` backend pass. Running ``nim ic`` again
  ## then recomputes DCE and emits the public routines plus their dependencies.
  var exports = publicRoutineSymbols(nimcacheDir, sourceRoot, exportConfig, mainSource)
  for symbol in exports:
    if symbol.iteratorRoutine:
      fail("native iterator exports currently require the normal C backend: " & symbol.nifSymbol)
  for hook in nativeHookSymbols(nimcacheDir, sourceRoot):
    if not hook.forbidden:
      exports.add NativeExportSymbol(
        sourcePath: hook.sourcePath, nifSymbol: hook.nifSymbol
      )
  var indexes = initTable[string, seq[int]]()
  for index, symbol in exports:
    indexes.mgetOrPut(symbol.backendSymbol, @[]).add index

  type Artifact = object
    path: string
    definitions: seq[CDefinition]
    ownsMain: bool

  let absoluteMain = normalizedAbsolutePath(mainSource)
  var artifacts: seq[Artifact]
  for path in walkFiles(nimcacheDir / "*.c.nif"):
    var artifact = Artifact(path: path, definitions: readCDefinitions(path))
    for definition in artifact.definitions:
      if definition.nifSymbol in indexes:
        for index in indexes[definition.nifSymbol]:
          if exports[index].sourcePath == absoluteMain:
            artifact.ownsMain = true
            break
        if artifact.ownsMain:
          break
    artifacts.add artifact
  artifacts.sort(
    proc(left, right: Artifact): int =
      if left.ownsMain != right.ownsMain:
        if left.ownsMain: 1 else: -1
      else:
        cmp(left.path, right.path)
  )

  for artifact in artifacts:
    var content = readFile(artifact.path)
    var changed = false
    for definition in artifact.definitions:
      if definition.nifSymbol in indexes:
        for index in indexes[definition.nifSymbol]:
          if exports[index].cSymbol.len == 0:
            exports[index].cSymbol = definition.cSymbol
          elif exports[index].cSymbol != definition.cSymbol:
            fail(
              "one semantic routine has multiple backend names: " & definition.nifSymbol
            )
        if 'x' notin definition.flags:
          changed = content.replaceDefinitionFlags(definition) or changed
    if changed:
      writeFile(artifact.path, content)

  result = resolveIncrementalNativeSymbols(nimcacheDir, exports)

proc prepareNativeRoutines*(
    nimcacheDir, sourceRoot, mainSource, cRootSource: string,
    exportConfig = NativeExportConfig(),
    cBuildManifest = "",
): NativeCodegenBackend =
  ## Prepares public routines for a second compiler pass.
  ##
  ## Incremental builds root matching ``.c.nif`` definitions in place. Normal
  ## C builds receive a generated module that takes the address of each public
  ## routine and exercises required ownership hooks in an uncalled helper.
  ## Inline routines receive out-of-line thunks with their original signatures.
  ## Iterators receive factories for independent, lazy closure state machines.
  ## ``cBuildManifest`` selects the compiler JSON build description explicitly
  ## when the cache contains more than one; otherwise it must be unambiguous.
  if cBuildManifest.len == 0 and nimcacheDir.hasIncrementalCArtifacts:
    if exportConfig.opaqueTypes.len > 0:
      fail("opaque native exports currently require the normal C backend")
    let statePath = cBuildStatePath(nimcacheDir)
    if fileExists(statePath):
      removeFile(statePath)
    discard rootPublicRoutines(nimcacheDir, sourceRoot, mainSource, exportConfig)
    result = ncbIncremental
  else:
    let manifest = findCBuildManifest(nimcacheDir, cBuildManifest)
    let recordedLibPath = cBuildState(nimcacheDir).getOrDefault("libPath").getStr
    let compilerLibPath = compilerCLibPath(manifest)
    writeFile(cBuildStatePath(nimcacheDir), (%*{
      "manifest": manifest,
      "projectPath": normalizedAbsolutePath(mainSource).parentDir,
      "libPath": (if compilerLibPath.len > 0: compilerLibPath else: recordedLibPath),
    }).pretty)
    let
      routines = publicRoutineSymbols(nimcacheDir, sourceRoot, exportConfig, mainSource)
      hooks = nativeHookSymbols(nimcacheDir, sourceRoot)
      opaqueExports =
        nativeOpaqueExports(nimcacheDir, sourceRoot, mainSource, exportConfig)
    let thunks =
      writeCBackendRoot(cRootSource, mainSource, routines, hooks, opaqueExports)
    let state = %*{
      "manifest": manifest,
      "projectPath": normalizedAbsolutePath(cRootSource).parentDir,
      "libPath": (if compilerLibPath.len > 0: compilerLibPath else: recordedLibPath),
      "thunks": thunks,
      "mainSource": normalizedAbsolutePath(mainSource),
    }
    writeFile(cBuildStatePath(nimcacheDir), state.pretty)
    result = ncbC

proc nativeExportSymbols*(
    nimcacheDir, sourceRoot: string, exportConfig = NativeExportConfig()
): seq[NativeExportSymbol] =
  ## Resolves the selected routine and ownership-hook names after codegen.
  var symbols = publicRoutineSymbols(nimcacheDir, sourceRoot, exportConfig,
    cBuildState(nimcacheDir).getOrDefault("mainSource").getStr)
  for hook in nativeHookSymbols(nimcacheDir, sourceRoot):
    if not hook.forbidden:
      symbols.add NativeExportSymbol(
        sourcePath: hook.sourcePath, nifSymbol: hook.nifSymbol
      )
  result = resolveNativeSymbols(nimcacheDir, symbols)
  if exportConfig.opaqueTypes.len == 0:
    return
  let mainSource = cBuildState(nimcacheDir).getOrDefault("mainSource").getStr
  let definitions = cBackendSymbols(nimcacheDir)
  for opaque in nativeOpaqueExports(nimcacheDir, sourceRoot, mainSource, exportConfig):
    for suffix in ["Destroy", "Copy", "Size", "Alignment"]:
      let name = opaque.hookPrefix & suffix
      if name notin definitions:
        fail("missing opaque ownership thunk: " & name)
      result.add NativeExportSymbol(sourcePath: opaque.sourcePath, cSymbol: name)

proc writeDarwinExportList*(
    path, initSymbol: string, symbols: openArray[NativeExportSymbol]
) =
  ## Writes an ld ``-exported_symbols_list`` with a unique runtime initializer.
  var names: seq[string]
  for symbol in symbols:
    if symbol.cSymbol != initSymbol:
      names.add "_" & symbol.cSymbol
  names.sort()
  var uniqueNames = @["_" & initSymbol]
  for name in names:
    if uniqueNames[^1] != name:
      uniqueNames.add name
  writeFile(path, uniqueNames.join("\n") & "\n")

proc writeElfVersionScript*(
    path, initSymbol: string, symbols: openArray[NativeExportSymbol]
) =
  ## Writes a GNU ld version script containing only the selected native API.
  var names: seq[string]
  for symbol in symbols:
    if symbol.cSymbol != initSymbol:
      names.add symbol.cSymbol
  names.sort()
  var lines = @["{", "  global:", "    " & initSymbol & ";"]
  var previous = ""
  for name in names:
    if name != previous:
      lines.add "    " & name & ";"
      previous = name
  lines.add "  local:"
  lines.add "    *;"
  lines.add "};"
  writeFile(path, lines.join("\n") & "\n")

proc writeWindowsModuleDefinition*(
    path, libraryName, initSymbol: string, symbols: openArray[NativeExportSymbol]
) =
  ## Writes a PE/COFF module-definition file with a unique runtime initializer.
  var names: seq[string]
  for symbol in symbols:
    if symbol.cSymbol != initSymbol:
      names.add symbol.cSymbol
  names.sort()
  var lines = @["LIBRARY " & libraryName.extractFilename, "EXPORTS"]
  lines.add "  " & initSymbol & "=NimMain"
  var previous = ""
  for name in names:
    if name != previous:
      lines.add "  " & name
      previous = name
  writeFile(path, lines.join("\n") & "\n")

proc writeNativeExportList*(
    path, initSymbol: string, symbols: openArray[NativeExportSymbol]
) =
  ## Writes the host linker's export-control file.
  when defined(macosx):
    writeDarwinExportList(path, initSymbol, symbols)
  elif defined(linux) or defined(freebsd):
    writeElfVersionScript(path, initSymbol, symbols)
  elif defined(windows):
    writeWindowsModuleDefinition(
      path, path.splitFile.name & ".dll", initSymbol, symbols
    )
  else:
    fail("native dynamic libraries are unsupported on " & hostOS)

func readU32(data: string, offset: int): uint32 =
  if offset < 0 or offset + 4 > data.len:
    fail("truncated native object")
  result =
    uint32(byte(data[offset])) or uint32(byte(data[offset + 1])) shl 8 or
    uint32(byte(data[offset + 2])) shl 16 or uint32(byte(data[offset + 3])) shl 24

func readU16(data: string, offset: int): uint16 =
  if offset < 0 or offset + 2 > data.len:
    fail("truncated native object")
  result = uint16(byte(data[offset])) or uint16(byte(data[offset + 1])) shl 8

func readU64(data: string, offset: int): uint64 =
  if offset < 0 or offset + 8 > data.len:
    fail("truncated native object")
  for index in 0 ..< 8:
    result = result or uint64(byte(data[offset + index])) shl (index * 8)

func checkedInt(value: uint64, path: string): int =
  if value > uint64(high(int)):
    fail("ELF offset exceeds host address space in " & path)
  result = int(value)

func rangeFits(offset, size, limit: int): bool =
  offset >= 0 and size >= 0 and offset <= limit and size <= limit - offset

proc objectString(data: string, offset, limit: int): string =
  if offset < 0 or offset >= limit or limit > data.len:
    return
  var index = offset
  while index < limit and data[index] != '\0':
    result.add data[index]
    inc index

proc patchMachOObject(
    path: string, symbols: HashSet[string], found: var HashSet[string]
): bool =
  var data = readFile(path)
  if data.len < machHeader64Size or data.readU32(0) != machMagic64:
    return false
  result = true

  let commandCount = int(data.readU32(16))
  var commandOffset = machHeader64Size
  var symtabOffset = -1
  var symbolCount = 0
  var stringOffset = -1
  var stringSize = 0
  for _ in 0 ..< commandCount:
    if commandOffset + 8 > data.len:
      fail("truncated Mach-O load commands in " & path)
    let
      command = data.readU32(commandOffset)
      commandSize = int(data.readU32(commandOffset + 4))
    if commandSize < 8 or commandOffset + commandSize > data.len:
      fail("invalid Mach-O load command in " & path)
    if command == loadCommandSymtab:
      if commandSize < 24:
        fail("invalid Mach-O symbol-table command in " & path)
      symtabOffset = int(data.readU32(commandOffset + 8))
      symbolCount = int(data.readU32(commandOffset + 12))
      stringOffset = int(data.readU32(commandOffset + 16))
      stringSize = int(data.readU32(commandOffset + 20))
    commandOffset += commandSize

  if symtabOffset < 0:
    return
  if symtabOffset + symbolCount * nlist64Size > data.len or stringOffset < 0 or
      stringOffset + stringSize > data.len:
    fail("invalid Mach-O symbol table in " & path)

  var changed = false
  for index in 0 ..< symbolCount:
    let
      entryOffset = symtabOffset + index * nlist64Size
      nameOffset = int(data.readU32(entryOffset))
      symbolName =
        data.objectString(stringOffset + nameOffset, stringOffset + stringSize)
      symbolType = uint8(data[entryOffset + 4])
      isDefinition = (symbolType and nTypeMask) != nTypeUndefined
    if symbolName in symbols and isDefinition:
      if (symbolType and nTypeExternal) == 0:
        fail("cannot promote local Mach-O symbol: " & symbolName)
      found.incl symbolName
      if (symbolType and nTypePrivateExternal) != 0:
        data[entryOffset + 4] = char(symbolType and not nTypePrivateExternal)
        changed = true
  if changed:
    writeFile(path, data)

proc patchElfObject(
    path: string, symbols: HashSet[string], found: var HashSet[string]
): bool =
  var data = readFile(path)
  if data.len < 4 or data[0] != '\x7f' or data[1] != 'E' or data[2] != 'L' or
      data[3] != 'F':
    return false
  result = true
  if data.len < elfHeader64Size:
    fail("truncated ELF object: " & path)
  if uint8(data[4]) != elfClass64:
    fail("only ELF64 objects can be promoted: " & path)
  if uint8(data[5]) != elfDataLittleEndian:
    fail("only little-endian ELF objects can be promoted: " & path)

  let
    sectionOffset = data.readU64(40).checkedInt(path)
    sectionEntrySize = int(data.readU16(58))
    sectionCount = int(data.readU16(60))
  if sectionEntrySize < elfSectionHeader64Size or sectionCount == 0 or
      not rangeFits(sectionOffset, sectionEntrySize * sectionCount, data.len):
    fail("invalid ELF section table in " & path)

  var changed = false
  for sectionIndex in 0 ..< sectionCount:
    let sectionHeader = sectionOffset + sectionIndex * sectionEntrySize
    let sectionType = data.readU32(sectionHeader + 4)
    if sectionType == elfSectionSymbolTable or sectionType == elfSectionDynamicSymbols:
      let
        symbolOffset = data.readU64(sectionHeader + 24).checkedInt(path)
        symbolSize = data.readU64(sectionHeader + 32).checkedInt(path)
        stringSectionIndex = int(data.readU32(sectionHeader + 40))
        symbolEntrySize = data.readU64(sectionHeader + 56).checkedInt(path)
      if stringSectionIndex < 0 or stringSectionIndex >= sectionCount or
          symbolEntrySize < elfSymbol64Size or
          not rangeFits(symbolOffset, symbolSize, data.len):
        fail("invalid ELF symbol table in " & path)

      let stringHeader = sectionOffset + stringSectionIndex * sectionEntrySize
      let
        stringOffset = data.readU64(stringHeader + 24).checkedInt(path)
        stringSize = data.readU64(stringHeader + 32).checkedInt(path)
      if not rangeFits(stringOffset, stringSize, data.len):
        fail("invalid ELF string table in " & path)

      let symbolCount = symbolSize div symbolEntrySize
      for symbolIndex in 0 ..< symbolCount:
        let entryOffset = symbolOffset + symbolIndex * symbolEntrySize
        if not rangeFits(entryOffset, elfSymbol64Size, data.len):
          fail("truncated ELF symbol table in " & path)
        let
          nameOffset = int(data.readU32(entryOffset))
          symbolName =
            data.objectString(stringOffset + nameOffset, stringOffset + stringSize)
          symbolInfo = uint8(data[entryOffset + 4])
          symbolOther = uint8(data[entryOffset + 5])
          symbolSection = data.readU16(entryOffset + 6)
          binding = symbolInfo shr 4
        if symbolName in symbols:
          if symbolSection != elfUndefinedSection:
            if binding != elfBindingGlobal and binding != elfBindingWeak:
              fail("cannot promote local ELF symbol: " & symbolName)
            found.incl symbolName
          if binding == elfBindingGlobal or binding == elfBindingWeak:
            if (symbolOther and elfVisibilityMask) != 0:
              data[entryOffset + 5] = char(symbolOther and not elfVisibilityMask)
              changed = true
  if changed:
    writeFile(path, data)

proc runProcess(command: string, arguments: openArray[string], workingDir = "") =
  var process = startProcess(
    command,
    workingDir = workingDir,
    args = @arguments,
    options = {poUsePath, poStdErrToStdOut},
  )
  let output = process.outputStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    fail(command & " failed with exit code " & $exitCode & ":\n" & output)

proc recordedCCompileCommand(path: string): seq[string] =
  const marker = "/* Command for C compiler:"
  let
    content = readFile(path)
    markerPosition = content.find(marker)
  if markerPosition < 0:
    fail("generated C source has no recorded compiler command: " & path)
  let
    commandStart = markerPosition + marker.len
    commandEnd = content.find(" */", commandStart)
  if commandEnd < 0:
    fail("generated C source has an incomplete compiler command: " & path)
  let commandText = content[commandStart ..< commandEnd].strip()
  if commandText.startsWith("assembled by the link stage"):
    # The incremental backend intentionally leaves the command assembly to
    # Nim's link stage. The actual per-module passC directives are in the
    # adjacent ``.cflags`` sidecar, so this comment is a sentinel rather than
    # an executable command.
    return
  result = parseCmdLine(commandText)
  if result.len < 2:
    fail("generated C source has an invalid compiler command: " & path)

proc recordedCCompileFlags(path: string): seq[string] =
  let flagsPath = path & ".cflags"
  if not fileExists(flagsPath):
    return
  for line in lines(flagsPath):
    let separator = line.find('\t')
    if separator < 0:
      continue
    let directive = line[0 ..< separator]
    if directive in ["passc", "localpassc"] and separator + 1 < line.len:
      result.add parseCmdLine(line[separator + 1 ..^ 1])

proc incrementalCCompileCommand(nimcacheDir, source: string): seq[string] =
  ## Reconstruct the small part of Nim's C command that the IC link stage
  ## normally assembles. ``ic_build_args.txt`` is emitted with every IC
  ## build and gives us the compiler's search paths; the sidecar supplies
  ## module-specific ``passC`` directives that are not present in the C
  ## placeholder comment.
  let buildArgsPath = nimcacheDir / "ic_build_args.txt"
  if not fileExists(buildArgsPath):
    fail("incremental C source has no build arguments: " & buildArgsPath)

  var includePaths: seq[string]
  for line in lines(buildArgsPath):
    let argument = line.strip()
    if argument.startsWith("--path:"):
      let includePath = argument["--path:".len ..^ 1]
      if includePath.len > 0 and dirExists(includePath) and
          includePath notin includePaths:
        includePaths.add includePath
  if includePaths.len == 0:
    fail("incremental C source has no compiler search paths: " & buildArgsPath)

  result = @["cc", "-c", "-w", "-fno-strict-aliasing", "-fPIC", "-pthread"]
  result.add recordedCCompileFlags(source)
  for includePath in includePaths:
    result.add "-I" & normalizedAbsolutePath(includePath)
  result.add [
    "-o", normalizedAbsolutePath(source & ".o"), normalizedAbsolutePath(source)
  ]

proc compileElfPicObjects*(nimcacheDir: string) =
  ## Recompiles generated C using Nim's recorded per-file flags plus ``-fPIC``.
  ##
  ## Normal C-backend files carry an exact compiler command in their header.
  ## Incremental-backend files instead say that the command is assembled by
  ## Nim's link stage; for those, reconstruct the command from the IC build
  ## arguments and the module's ``.cflags`` sidecar.
  var sources: seq[string]
  for path in walkFiles(nimcacheDir / "*.c"):
    sources.add path
  sources.sort()
  if sources.len == 0:
    fail("incremental backend emitted no C sources in " & nimcacheDir)

  for source in sources:
    if getFileSize(source) == 0:
      continue
    let recordedCommand = recordedCCompileCommand(source)
    if recordedCommand.len == 0:
      let command = incrementalCCompileCommand(nimcacheDir, source)
      runProcess(command[0], command[1 ..^ 1])
    else:
      var arguments = recordedCommand[1 ..^ 1]
      arguments.add "-fPIC"
      runProcess(recordedCommand[0], arguments)

proc promoteMachOArchive*(
    inputPath, outputPath: string, symbols: openArray[NativeExportSymbol]
) =
  ## Clears ``N_PEXT`` for selected definitions and writes a new archive.
  let
    input = normalizedAbsolutePath(inputPath)
    output = normalizedAbsolutePath(outputPath)
    temporary = createTempDir("binny-native-dynlib-", "")
  defer:
    removeDir(temporary)

  runProcess("ar", ["-x", input], temporary)

  var requested = initHashSet[string]()
  for symbol in symbols:
    requested.incl "_" & symbol.cSymbol
  var found = initHashSet[string]()
  var members: seq[string]
  for path in walkFiles(temporary / "*"):
    if patchMachOObject(path, requested, found):
      members.add path
  members.sort()
  if members.len == 0:
    fail("static archive contains no members: " & input)

  var missing: seq[string]
  for symbol in requested:
    if symbol notin found:
      missing.add symbol
  if missing.len > 0:
    missing.sort()
    fail("archive has no promotable definitions for:\n  " & missing.join("\n  "))

  createDir(output.parentDir)
  if fileExists(output):
    removeFile(output)
  var arguments = @["-rcs", output]
  arguments.add members
  runProcess("ar", arguments)

proc promoteElfArchive*(
    inputPath, outputPath: string, symbols: openArray[NativeExportSymbol]
) =
  ## Gives selected ELF definitions and references default visibility.
  let
    input = normalizedAbsolutePath(inputPath)
    output = normalizedAbsolutePath(outputPath)
    temporary = createTempDir("binny-native-dynlib-", "")
  defer:
    removeDir(temporary)

  runProcess("ar", ["-x", input], temporary)

  var requested = initHashSet[string]()
  for symbol in symbols:
    requested.incl symbol.cSymbol
  var found = initHashSet[string]()
  var members: seq[string]
  for path in walkFiles(temporary / "*"):
    if patchElfObject(path, requested, found):
      members.add path
  members.sort()
  if members.len == 0:
    fail("static archive contains no ELF members: " & input)

  var missing: seq[string]
  for symbol in requested:
    if symbol notin found:
      missing.add symbol
  if missing.len > 0:
    missing.sort()
    fail("archive has no promotable definitions for:\n  " & missing.join("\n  "))

  createDir(output.parentDir)
  if fileExists(output):
    removeFile(output)
  var arguments = @["-rcs", output]
  arguments.add members
  runProcess("ar", arguments)

proc promoteCoffArchive*(
    inputPath, outputPath: string, symbols: openArray[NativeExportSymbol]
) =
  ## COFF external definitions need no visibility rewrite; preserve the archive.
  ## The final PE export check validates the selected symbols after linking.
  discard symbols
  let
    input = normalizedAbsolutePath(inputPath)
    output = normalizedAbsolutePath(outputPath)
  createDir(output.parentDir)
  if fileExists(output):
    removeFile(output)
  copyFile(input, output)

proc promoteNativeArchive*(
    inputPath, outputPath: string, symbols: openArray[NativeExportSymbol]
) =
  ## Promotes selected definitions using the host object format.
  when defined(macosx):
    promoteMachOArchive(inputPath, outputPath, symbols)
  elif defined(linux) or defined(freebsd):
    promoteElfArchive(inputPath, outputPath, symbols)
  elif defined(windows):
    promoteCoffArchive(inputPath, outputPath, symbols)
  else:
    fail("native dynamic libraries are unsupported on " & hostOS)

proc linkMachODylib*(
    archivePath, outputPath, exportListPath, initSymbol: string,
    installName = "",
    linkerArgs: openArray[string] = [],
) =
  ## Links every member of a promoted archive into a symbol-filtered dylib.
  let dylibName =
    if installName.len > 0:
      installName
    else:
      "@rpath/" & outputPath.extractFilename
  let runtimeDir = createTempDir("binny-native-runtime-", "")
  defer:
    removeDir(runtimeDir)
  let
    runtimeSource = runtimeDir / "runtime.c"
    runtimeObject = runtimeDir / "runtime.o"
  writeFile(runtimeSource, "int cmdCount;\nchar **cmdLine;\n")
  runProcess("clang", ["-c", "-fPIC", runtimeSource, "-o", runtimeObject])
  createDir(outputPath.parentDir)
  var arguments =
    @[
      "-dynamiclib",
      "-Wl,-force_load," & normalizedAbsolutePath(archivePath),
      runtimeObject,
      "-Wl,-alias,_NimMain,_" & initSymbol,
      "-Wl,-exported_symbols_list," & normalizedAbsolutePath(exportListPath),
      "-Wl,-install_name," & dylibName,
    ]
  arguments.add linkerArgs
  arguments.add ["-o", normalizedAbsolutePath(outputPath)]
  runProcess("clang", arguments)

proc linkElfSharedLibrary*(
    archivePath, outputPath, exportListPath, initSymbol: string,
    soname = "",
    linkerArgs: openArray[string] = [],
) =
  ## Links every archive member into a version-script-filtered ELF shared object.
  let libraryName = if soname.len > 0: soname else: outputPath.extractFilename
  createDir(outputPath.parentDir)
  let
    temporary = createTempDir("binny-native-runtime-", "")
    runtimeScript = temporary / "runtime.ld"
  defer:
    removeDir(temporary)
  writeFile(
    runtimeScript,
    """SECTIONS
{
  .binny_runtime (NOLOAD) :
  {
    PROVIDE(cmdCount = .);
    LONG(0);
    . = ALIGN(8);
    PROVIDE(cmdLine = .);
    QUAD(0);
  }
}
INSERT AFTER .bss;
""",
  )
  # Nim emits direct references for hidden definitions. Keep those references
  # locally bound after promoting the selected definitions to default visibility.
  var arguments =
    @[
      "-shared",
      "-Wl,-z,defs",
      "-Wl,-Bsymbolic",
      "-Wl,--whole-archive",
      normalizedAbsolutePath(archivePath),
      "-Wl,--no-whole-archive",
      "-Wl,--defsym=" & initSymbol & "=NimMain",
      "-Wl,--version-script," & normalizedAbsolutePath(exportListPath),
      "-Wl,-T," & normalizedAbsolutePath(runtimeScript),
      "-Wl,-soname," & libraryName,
      "-pthread",
      "-ldl",
      "-lm",
    ]
  arguments.add linkerArgs
  arguments.add ["-o", normalizedAbsolutePath(outputPath)]
  runProcess("cc", arguments)

proc linkWindowsDll*(
    archivePath, outputPath, exportListPath, initSymbol: string,
    linkerArgs: openArray[string] = [],
) =
  ## Links every archive member into a module-definition-filtered PE DLL.
  discard initSymbol
  let temporary = createTempDir("binny-native-runtime-", "")
  defer:
    removeDir(temporary)
  let
    runtimeSource = temporary / "runtime.c"
    runtimeObject = temporary / "runtime.o"
    exportDefinition = temporary / "native_exports.def"
  writeFile(runtimeSource, "int cmdCount;\nchar **cmdLine;\n")
  runProcess("gcc", ["-c", runtimeSource, "-o", runtimeObject])
  # GNU ld recognizes PE module-definition files by their ``.def`` suffix.
  # The public export-list path intentionally uses ``.exports`` on every
  # platform, so give the Windows linker a temporary DEF-named copy.
  copyFile(normalizedAbsolutePath(exportListPath), exportDefinition)
  createDir(outputPath.parentDir)
  var arguments =
    @[
      "-shared",
      "-Wl,--whole-archive",
      normalizedAbsolutePath(archivePath),
      "-Wl,--no-whole-archive",
      runtimeObject,
      exportDefinition,
    ]
  arguments.add linkerArgs
  arguments.add ["-o", normalizedAbsolutePath(outputPath)]
  runProcess("gcc", arguments)

proc linkNativeDynlib*(
    archivePath, outputPath, exportListPath, initSymbol: string,
    libraryName = "",
    linkerArgs: openArray[string] = [],
) =
  ## Links a filtered native dynamic library using the host linker.
  when defined(macosx):
    linkMachODylib(
      archivePath, outputPath, exportListPath, initSymbol, libraryName, linkerArgs
    )
  elif defined(linux) or defined(freebsd):
    linkElfSharedLibrary(
      archivePath, outputPath, exportListPath, initSymbol, libraryName, linkerArgs
    )
  elif defined(windows):
    linkWindowsDll(archivePath, outputPath, exportListPath, initSymbol, linkerArgs)
  else:
    fail("native dynamic libraries are unsupported on " & hostOS)
