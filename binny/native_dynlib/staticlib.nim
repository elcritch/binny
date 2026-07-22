## Builds a native Nim export surface from semantic BIF and compiler artifacts.
##
## The incremental C backend records every owned routine in ``.c.nif`` before
## whole-program dead-code elimination. This module matches public routine
## declarations from semantic BIF to those backend definitions, keeps them live,
## and promotes the resulting Mach-O symbols after they are archived.

import std/[algorithm, os, osproc, sets, streams, strutils, tables, tempfiles]
import nif/[bif, nifcore, nifcoreparse, nifqueries]

type
  NativeStaticLibError* = object of CatchableError

  NativeExportSymbol* = object
    sourcePath*: string
    nifSymbol*: string
    cSymbol*: string

  NativeHookSymbol* = object
    sourcePath*: string
    typeSymbol*: string
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

proc fail(message: string) {.noreturn.} =
  raise newException(NativeStaticLibError, message)

func semanticModule(symbol: string): string =
  let separator = symbol.rfind('.')
  if separator >= 0:
    result = symbol[separator + 1..^1]

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

proc publicRoutineSymbols*(nimcacheDir, sourceRoot: string): seq[NativeExportSymbol] =
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
    if not pathIsWithin(absoluteSource, root):
      continue

    let moduleSuffix = bifModuleSuffix(path)
    for name, visibility, declaration in module.declarations:
      if visibility == ivExported and semanticModule(name) == moduleSuffix and
          declaration.isRoutineDeclaration:
        result.add NativeExportSymbol(sourcePath: absoluteSource, nifSymbol: name)

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
    var publicTypes = initHashSet[string]()
    for name, visibility, declaration in module.declarations:
      if visibility == ivExported and semanticModule(name) == moduleSuffix and
          not declaration.findChildTag("type").cursorIsNil:
        let typeSymbol = declaration.declarationTypeSymbol()
        if typeSymbol.len > 0:
          publicTypes.incl typeSymbol

    for name, visibility, declaration in module.declarations:
      if visibility == ivHidden and semanticModule(name) == moduleSuffix and
          name.symbolBase in hookKinds and declaration.isSourceRoutineDeclaration:
        let typeSymbol = declaration.firstParameterType()
        if typeSymbol in publicTypes:
          result.add NativeHookSymbol(
            sourcePath: absoluteSource,
            typeSymbol: typeSymbol,
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

proc replaceDefinitionFlags(content: var string; definition: CDefinition): bool =
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

proc resolveNativeSymbols*(nimcacheDir: string;
    symbols: openArray[NativeExportSymbol]): seq[NativeExportSymbol] =
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
          fail("one semantic routine has multiple backend names: " &
            definition.nifSymbol)
        matched.incl definition.nifSymbol

  var missing: seq[string]
  for symbol in result:
    if symbol.nifSymbol notin matched:
      missing.add symbol.nifSymbol
  if missing.len > 0:
    missing.sort()
    fail("native routines have no backend definitions:\n  " & missing.join("\n  "))

proc resolveNativeHooks*(nimcacheDir: string;
    hooks: openArray[NativeHookSymbol]): seq[NativeHookSymbol] =
  ## Adds exact backend names to custom hooks; forbidden hooks have no definition.
  result = @hooks
  var unresolved: seq[NativeExportSymbol]
  var indexes: seq[int]
  for index, hook in result:
    if not hook.forbidden:
      indexes.add index
      unresolved.add NativeExportSymbol(
        sourcePath: hook.sourcePath,
        nifSymbol: hook.nifSymbol,
      )
  let resolved = resolveNativeSymbols(nimcacheDir, unresolved)
  for index, symbol in resolved:
    result[indexes[index]].cSymbol = symbol.cSymbol

proc rootPublicRoutines*(nimcacheDir, sourceRoot, mainSource: string): seq[NativeExportSymbol] =
  ## Roots public app routines and ownership hooks required by public types.
  ##
  ## Run this after the first ``nim ic`` backend pass. Running ``nim ic`` again
  ## then recomputes DCE and emits the public routines plus their dependencies.
  var exports = publicRoutineSymbols(nimcacheDir, sourceRoot)
  for hook in nativeHookSymbols(nimcacheDir, sourceRoot):
    if not hook.forbidden:
      exports.add NativeExportSymbol(
        sourcePath: hook.sourcePath,
        nifSymbol: hook.nifSymbol,
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
  artifacts.sort(proc(left, right: Artifact): int =
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
          fail("one semantic routine has multiple backend names: " &
            definition.nifSymbol)
        if 'x' notin definition.flags:
          changed = content.replaceDefinitionFlags(definition) or changed
    if changed:
      writeFile(artifact.path, content)

  result = resolveNativeSymbols(nimcacheDir, exports)

proc writeDarwinExportList*(path: string; symbols: openArray[NativeExportSymbol]) =
  ## Writes an ld ``-exported_symbols_list`` including the Nim runtime entry.
  var names = @["_NimMain"]
  for symbol in symbols:
    names.add "_" & symbol.cSymbol
  names.sort()
  var uniqueNames: seq[string]
  for name in names:
    if uniqueNames.len == 0 or uniqueNames[^1] != name:
      uniqueNames.add name
  writeFile(path, uniqueNames.join("\n") & "\n")

func readU32(data: string; offset: int): uint32 =
  if offset < 0 or offset + 4 > data.len:
    fail("truncated Mach-O object")
  result = uint32(byte(data[offset])) or
    uint32(byte(data[offset + 1])) shl 8 or
    uint32(byte(data[offset + 2])) shl 16 or
    uint32(byte(data[offset + 3])) shl 24

proc machString(data: string; offset, limit: int): string =
  if offset < 0 or offset >= limit or limit > data.len:
    return
  var index = offset
  while index < limit and data[index] != '\0':
    result.add data[index]
    inc index

proc patchMachOObject(
    path: string; symbols: HashSet[string]; found: var HashSet[string]
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
  if symtabOffset + symbolCount * nlist64Size > data.len or
      stringOffset < 0 or stringOffset + stringSize > data.len:
    fail("invalid Mach-O symbol table in " & path)

  var changed = false
  for index in 0 ..< symbolCount:
    let
      entryOffset = symtabOffset + index * nlist64Size
      nameOffset = int(data.readU32(entryOffset))
      symbolName = data.machString(stringOffset + nameOffset,
        stringOffset + stringSize)
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

proc runProcess(command: string; arguments: openArray[string]; workingDir = "") =
  var process = startProcess(command, workingDir = workingDir, args = @arguments,
    options = {poUsePath, poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    fail(command & " failed with exit code " & $exitCode & ":\n" & output)

proc promoteMachOArchive*(inputPath, outputPath: string;
                          symbols: openArray[NativeExportSymbol]) =
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

proc linkMachODylib*(archivePath, outputPath, exportListPath: string;
                     installName = "") =
  ## Links every member of a promoted archive into a symbol-filtered dylib.
  let dylibName = if installName.len > 0:
    installName
  else:
    "@rpath/" & outputPath.extractFilename
  createDir(outputPath.parentDir)
  runProcess("clang", [
    "-dynamiclib",
    "-Wl,-force_load," & normalizedAbsolutePath(archivePath),
    "-Wl,-exported_symbols_list," & normalizedAbsolutePath(exportListPath),
    "-Wl,-install_name," & dylibName,
    "-o", normalizedAbsolutePath(outputPath),
  ])
