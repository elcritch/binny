## Builds a native Nim export surface from semantic BIF and compiler artifacts.
##
## This module matches public routine declarations from semantic BIF to compiler
## C artifacts, keeps the selected routines live across whole-program dead-code
## elimination, and promotes their Mach-O or ELF symbols after archiving.

import std/[algorithm, cmdline, os, osproc, sets, streams, strutils, tables, tempfiles]
import nif/[bif, nifcore, nifcoreparse, nifqueries]
import exportconfig

type
  NativeStaticLibError* = object of CatchableError

  NativeCodegenBackend* = enum
    ncbC
    ncbIncremental

  NativeExportSymbol* = object
    sourcePath*: string
    nifSymbol*: string
    cSymbol*: string

  NativeHookSymbol* = object
    sourcePath*: string
    typeSymbol*: string
    typeName*: string
    hookKind*: string
    nifSymbol*: string
    cSymbol*: string
    forbidden*: bool

  CDefinition = object
    nifSymbol: string
    cSymbol: string
    flags: string

const
  routineKinds = ["proc", "func", "method", "converter"]
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
  result = relative != ".." and not relative.startsWith(".." & $DirSep)

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
        return true
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

proc applyExportConfig(
    symbols: openArray[NativeExportSymbol],
    sourceRoot: string,
    exportConfig: NativeExportConfig,
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
      if selector.matches(source, name):
        includedMatches[index] = true
        included = true
    var excluded = false
    for index, selector in exportConfig.excludeProcs:
      if selector.matches(source, name):
        matched[index] = true
        excluded = true
    if included and not excluded:
      result.add symbol

  if exportConfig.requireMatches:
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
    nimcacheDir, sourceRoot: string, exportConfig = NativeExportConfig()
): seq[NativeExportSymbol] =
  ## Returns public, runtime routine declarations owned by application modules.
  ##
  ## ``sourceRoot`` bounds the application: public routines from the compiler
  ## and external dependencies in the same nimcache are deliberately excluded.
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
    if not pathIsWithin(absoluteSource, root) and exportConfig.includeProcs.len == 0:
      continue

    let moduleSuffix = bifModuleSuffix(path)
    for name, visibility, declaration in module.declarations:
      if visibility == ivExported and semanticModule(name) == moduleSuffix and
          declaration.isRoutineDeclaration:
        result.add NativeExportSymbol(sourcePath: absoluteSource, nifSymbol: name)
  result = applyExportConfig(result, sourceRoot, exportConfig)

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
  var indexes = initTable[string, int]()
  for index, symbol in result:
    indexes[symbol.nifSymbol] = index

  var matched = initHashSet[string]()
  for path in walkFiles(nimcacheDir / "*.c.nif"):
    for definition in readCDefinitions(path):
      if definition.nifSymbol in indexes:
        let index = indexes[definition.nifSymbol]
        if result[index].cSymbol.len == 0:
          result[index].cSymbol = definition.cSymbol
        elif result[index].cSymbol != definition.cSymbol:
          fail(
            "one semantic routine has multiple backend names: " & definition.nifSymbol
          )
        matched.incl definition.nifSymbol

  var missing: seq[string]
  for symbol in result:
    if symbol.nifSymbol notin matched:
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

proc cBackendSymbols(nimcacheDir: string): Table[string, HashSet[string]] =
  for path in walkFiles(nimcacheDir / "*.c"):
    let content = readFile(path)
    var position = 0
    while position < content.len:
      if not content[position].isCIdentifierCharacter:
        inc position
        continue
      var ending = position + 1
      while ending < content.len and content[ending].isCIdentifierCharacter:
        inc ending
      let token = content[position ..< ending]
      let prefix = token.cTokenPrefix
      if prefix.len > 0 and token.len > prefix.len:
        result.mgetOrPut(prefix, initHashSet[string]()).incl token
      position = ending

proc resolveCNativeSymbols(
    nimcacheDir: string, symbols: openArray[NativeExportSymbol]
): seq[NativeExportSymbol] =
  result = @symbols
  var moduleIndexes: Table[string, seq[int]]
  var candidates = newSeq[HashSet[string]](result.len)
  var missing: seq[string]
  let backendSymbols = cBackendSymbols(nimcacheDir)
  for index, symbol in result:
    let prefix = symbol.nifSymbol.cSymbolPrefix
    if prefix.len == 0:
      missing.add symbol.nifSymbol
    else:
      candidates[index] = backendSymbols.getOrDefault(prefix)
      if candidates[index].len == 0:
        missing.add symbol.nifSymbol
    moduleIndexes.mgetOrPut(symbol.nifSymbol.semanticModule, @[]).add index
  if missing.len > 0:
    missing.sort()
    fail("native routines have no C backend definitions:\n  " & missing.join("\n  "))

  for module, indexes in moduleIndexes:
    var commonSuffixes: HashSet[string]
    var first = true
    for index in indexes:
      let prefix = result[index].nifSymbol.cSymbolPrefix
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
      let candidate = result[index].nifSymbol.cSymbolPrefix & suffix
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
  if nimcacheDir.hasIncrementalCArtifacts:
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
    outputPath: string,
    routines: openArray[NativeExportSymbol],
    hooks: openArray[NativeHookSymbol],
) =
  var routineNamesBySource: Table[string, seq[string]]
  var sources: seq[string]
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
  sources.sort()

  var aliases: Table[string, string]
  var content = "## Generated by Binny to keep public native routines reachable.\n\n"
  content.add "import std/macros\n"
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
        "nnkMethodDef, nnkConverterDef, nnkIteratorDef} and\n"
      content.add "        implementation[2].kind == nnkEmpty:\n"
      content.add "      result.add newLetStmt(genSym(nskLet, " &
        "\"binnyRoot\"), symbol)\n"
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
  var exports = publicRoutineSymbols(nimcacheDir, sourceRoot, exportConfig)
  for hook in nativeHookSymbols(nimcacheDir, sourceRoot):
    if not hook.forbidden:
      exports.add NativeExportSymbol(
        sourcePath: hook.sourcePath, nifSymbol: hook.nifSymbol
      )
  var indexes = initTable[string, int]()
  for index, symbol in exports:
    indexes[symbol.nifSymbol] = index

  type Artifact = object
    path: string
    definitions: seq[CDefinition]
    ownsMain: bool

  let absoluteMain = normalizedAbsolutePath(mainSource)
  var artifacts: seq[Artifact]
  for path in walkFiles(nimcacheDir / "*.c.nif"):
    var artifact = Artifact(path: path, definitions: readCDefinitions(path))
    for definition in artifact.definitions:
      if definition.nifSymbol in indexes and
          exports[indexes[definition.nifSymbol]].sourcePath == absoluteMain:
        artifact.ownsMain = true
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
        let index = indexes[definition.nifSymbol]
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

  result = resolveNativeSymbols(nimcacheDir, exports)

proc prepareNativeRoutines*(
    nimcacheDir, sourceRoot, mainSource, cRootSource: string,
    exportConfig = NativeExportConfig(),
): NativeCodegenBackend =
  ## Prepares public routines for a second compiler pass.
  ##
  ## Incremental builds root matching ``.c.nif`` definitions in place. Normal
  ## C builds receive a generated module that takes the address of each public
  ## routine and exercises required ownership hooks in an uncalled helper.
  if nimcacheDir.hasIncrementalCArtifacts:
    discard rootPublicRoutines(nimcacheDir, sourceRoot, mainSource, exportConfig)
    result = ncbIncremental
  else:
    let
      routines = publicRoutineSymbols(nimcacheDir, sourceRoot, exportConfig)
      hooks = nativeHookSymbols(nimcacheDir, sourceRoot)
    writeCBackendRoot(cRootSource, routines, hooks)
    result = ncbC

proc nativeExportSymbols*(
    nimcacheDir, sourceRoot: string, exportConfig = NativeExportConfig()
): seq[NativeExportSymbol] =
  ## Resolves the selected routine and ownership-hook names after codegen.
  var symbols = publicRoutineSymbols(nimcacheDir, sourceRoot, exportConfig)
  for hook in nativeHookSymbols(nimcacheDir, sourceRoot):
    if not hook.forbidden:
      symbols.add NativeExportSymbol(
        sourcePath: hook.sourcePath, nifSymbol: hook.nifSymbol
      )
  result = resolveNativeSymbols(nimcacheDir, symbols)

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

proc writeNativeExportList*(
    path, initSymbol: string, symbols: openArray[NativeExportSymbol]
) =
  ## Writes the host linker's export-control file.
  when defined(macosx):
    writeDarwinExportList(path, initSymbol, symbols)
  elif defined(linux) or defined(freebsd):
    writeElfVersionScript(path, initSymbol, symbols)
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
  result = parseCmdLine(content[commandStart ..< commandEnd].strip())
  if result.len < 2:
    fail("generated C source has an invalid compiler command: " & path)

proc compileElfPicObjects*(nimcacheDir: string) =
  ## Recompiles generated C using Nim's recorded per-file flags plus ``-fPIC``.
  ##
  ## The incremental backend currently does not apply command-line ``passC``
  ## options to its C compilation graph. Nim records the exact compiler command
  ## in every generated C file, including module-specific pragma flags, so
  ## replaying it preserves those flags while making the objects linkable into
  ## an ELF shared library.
  var sources: seq[string]
  for path in walkFiles(nimcacheDir / "*.c"):
    sources.add path
  sources.sort()
  if sources.len == 0:
    fail("incremental backend emitted no C sources in " & nimcacheDir)

  for source in sources:
    if getFileSize(source) == 0:
      continue
    let command = recordedCCompileCommand(source)
    var arguments = command[1 ..^ 1]
    arguments.add "-fPIC"
    runProcess(command[0], arguments)

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

proc promoteNativeArchive*(
    inputPath, outputPath: string, symbols: openArray[NativeExportSymbol]
) =
  ## Promotes selected definitions using the host object format.
  when defined(macosx):
    promoteMachOArchive(inputPath, outputPath, symbols)
  elif defined(linux) or defined(freebsd):
    promoteElfArchive(inputPath, outputPath, symbols)
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
  createDir(outputPath.parentDir)
  var arguments =
    @[
      "-dynamiclib",
      "-Wl,-force_load," & normalizedAbsolutePath(archivePath),
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
  else:
    fail("native dynamic libraries are unsupported on " & hostOS)
