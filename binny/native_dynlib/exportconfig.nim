## Configures which public Nim procedures become native dynamic-library exports.

import std/[json, os, strutils]

type
  NativeExportConfigError* = object of ValueError

  NativeProcSelector* = object
    ## A source-relative public procedure selector.
    ##
    ## ``source`` and ``name`` accept ``*`` as a zero-or-more-character glob.
    ## An empty ``source`` matches every application source file.
    source*: string
    name*: string
    typeArgs*: seq[string] ## Optional exact concrete generic arguments.
      ## Named types use ``source.nim:Type`` relative to the producer's source root.

  NativeTypeImport* = object
    ## Reuses a type declared by an imported Nim module. ``name`` is the
    ## unqualified ABI type name and ``module`` is its Nim import path.
    name*: string
    module*: string
    source*: string ## Optional source-relative producer ownership selector, with ``*`` globs.
    ## Re-exports the imported type from generated bindings unless disabled.
    exported*: bool

  NativeOpaqueType* = object
    ## Exports a named type with private ABI-compatible storage, not its fields.
    name*: string
    source*: string ## Optional source-relative ownership selector, with ``*`` globs.

  NativeExportConfig* = object
    ## When non-empty, only matching public procedures become exports.
    includeProcs*: seq[NativeProcSelector]
    ## Public procedures removed from the native export surface.
    excludeProcs*: seq[NativeProcSelector]
    ## Raise an error when an inclusion or exclusion matches no public procedure.
    requireMatches*: bool
    ## Types that generated bindings should import instead of redeclaring.
    typeImports*: seq[NativeTypeImport]
    ## Types whose implementation fields stay inside the producer.
    opaqueTypes*: seq[NativeOpaqueType]
    ## Reject selected procedures whose resolved exception effects are non-empty
    ## or unknown. Enabled by ``-d:features.binny.forbidExceptions`` by default.
    forbidExceptions*: bool

const defaultForbidExceptions* = defined(features.binny.forbidExceptions)

proc fail(message: string) {.noinline, noreturn.} =
  raise newException(NativeExportConfigError, message)

func excludeProc*(name: string, source = "", typeArgs: seq[string] = @[]): NativeProcSelector =
  ## Selects procedures to exclude by source-relative path and Nim name.
  ## Write quoted names without backticks, for example ``foo=`` or ``for``.
  NativeProcSelector(source: source.replace('\\', '/'), name: name, typeArgs: typeArgs)

func includeProc*(name: string, source = "", typeArgs: seq[string] = @[]): NativeProcSelector =
  ## Selects a public procedure to include by source-relative path and Nim name.
  ## Write quoted names without backticks, for example ``foo=`` or ``for``.
  NativeProcSelector(source: source.replace('\\', '/'), name: name, typeArgs: typeArgs)

func importType*(name, module: string, exported = true, source = ""): NativeTypeImport =
  ## Selects a generated type to reuse from an imported Nim module.
  ## Set ``exported`` to false to keep it private to the generated module.
  NativeTypeImport(
    name: name, module: module.replace('\\', '/'), exported: exported,
    source: source.replace('\\', '/')
  )

func opaqueType*(name: string, source = ""): NativeOpaqueType =
  ## Selects one public record or record reference for opaque native export.
  ## Ambiguous names require a source selector; imported types cannot be opaque.
  NativeOpaqueType(name: name, source: source.replace('\\', '/'))

proc validateSelector(selector: NativeProcSelector, description: string) =
  if selector.name.len == 0:
    fail(description & " has an empty procedure name")
  if '`' in selector.name:
    fail(description & " names must omit backticks: " & selector.name)
  if selector.source.isAbsolute:
    fail(description & " source must be relative: " & selector.source)
  for argument in selector.typeArgs:
    if argument.len == 0:
      fail(description & " has an empty generic argument")

proc validateTypeImport(typeImport: NativeTypeImport, description: string) =
  if typeImport.name.len == 0:
    fail(description & " has an empty type name")
  if '`' in typeImport.name or '.' in typeImport.name or '/' in typeImport.name:
    fail(description & " names must be unqualified and omit backticks: " & typeImport.name)
  if typeImport.module.len == 0:
    fail(description & " has an empty module name")
  if typeImport.module.isAbsolute:
    fail(description & " module must be relative: " & typeImport.module)
  if typeImport.source.isAbsolute:
    fail(description & " source must be relative: " & typeImport.source)
  for character in typeImport.module:
    if character notin {
      'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '/', '.', '-'
    }:
      fail(description & " module contains an invalid character: " & typeImport.module)

proc validateNativeExportConfig*(config: NativeExportConfig) =
  ## Validates selector spellings before applying an export configuration.
  for selector in config.excludeProcs:
    selector.validateSelector("native export exclusion")
  for selector in config.includeProcs:
    selector.validateSelector("native export inclusion")
  for index, typeImport in config.typeImports:
    typeImport.validateTypeImport("native type import[" & $index & "]")
  for opaque in config.opaqueTypes:
    if opaque.name.len == 0 or '`' in opaque.name or '*' in opaque.name or
        '.' in opaque.name or '/' in opaque.name or opaque.source.isAbsolute:
      fail("invalid native opaque type selector: " & opaque.name)

proc initNativeExportConfig*(
    excludeProcs: openArray[NativeProcSelector] = [],
    requireMatches = true,
    includeProcs: openArray[NativeProcSelector] = [],
    typeImports: openArray[NativeTypeImport] = [],
    opaqueTypes: openArray[NativeOpaqueType] = [],
    forbidExceptions = defaultForbidExceptions,
): NativeExportConfig =
  ## Creates a validated native export configuration.
  result.excludeProcs = @excludeProcs
  result.includeProcs = @includeProcs
  result.requireMatches = requireMatches
  result.typeImports = @typeImports
  result.opaqueTypes = @opaqueTypes
  result.forbidExceptions = forbidExceptions
  result.validateNativeExportConfig()

func globMatches(value, pattern: string): bool =
  var
    valueIndex = 0
    patternIndex = 0
    starIndex = -1
    starValueIndex = 0

  while valueIndex < value.len:
    if patternIndex < pattern.len and pattern[patternIndex] == value[valueIndex]:
      inc valueIndex
      inc patternIndex
    elif patternIndex < pattern.len and pattern[patternIndex] == '*':
      starIndex = patternIndex
      starValueIndex = valueIndex
      inc patternIndex
    elif starIndex >= 0:
      patternIndex = starIndex + 1
      inc starValueIndex
      valueIndex = starValueIndex
    else:
      return false

  while patternIndex < pattern.len and pattern[patternIndex] == '*':
    inc patternIndex
  result = patternIndex == pattern.len

func matches*(selector: NativeProcSelector, source, name: string): bool =
  ## Matches source/name; concrete ``typeArgs`` are checked against BIF evidence.
  let sourceMatches =
    selector.source.len == 0 or
    globMatches(source.replace('\\', '/'), selector.source.replace('\\', '/'))
  result = sourceMatches and globMatches(name, selector.name)

proc requireObject(node: JsonNode, description: string) =
  if node.kind != JObject:
    fail(description & " must be a JSON object")

proc rejectUnknownFields(
    node: JsonNode, allowed: openArray[string], description: string
) =
  for key in node.keys:
    if key notin allowed:
      fail(description & " has an unknown field: " & key)

proc parseSelector(node: JsonNode, field: string, index: int): NativeProcSelector =
  let description = field & "[" & $index & "]"
  node.requireObject(description)
  node.rejectUnknownFields(["source", "name", "typeArgs"], description)
  if not node.hasKey("name") or node["name"].kind != JString:
    fail(description & ".name must be a string")
  if node.hasKey("source") and node["source"].kind != JString:
    fail(description & ".source must be a string")
  result = NativeProcSelector(
    source:
      if node.hasKey("source"):
        node["source"].getStr.replace('\\', '/')
      else:
        "",
    name: node["name"].getStr,
  )
  if node.hasKey("typeArgs"):
    if node["typeArgs"].kind != JArray:
      fail(description & ".typeArgs must be an array of strings")
    for argument in node["typeArgs"]:
      if argument.kind != JString:
        fail(description & ".typeArgs must contain strings")
      result.typeArgs.add argument.getStr

proc parseTypeImport(node: JsonNode, index: int): NativeTypeImport =
  let description = "typeImports[" & $index & "]"
  node.requireObject(description)
  node.rejectUnknownFields(["name", "module", "export", "source"], description)
  if not node.hasKey("name") or node["name"].kind != JString:
    fail(description & ".name must be a string")
  if not node.hasKey("module") or node["module"].kind != JString:
    fail(description & ".module must be a string")
  var exported = true
  if node.hasKey("export"):
    if node["export"].kind != JBool:
      fail(description & ".export must be a boolean")
    exported = node["export"].getBool
  if node.hasKey("source") and node["source"].kind != JString:
    fail(description & ".source must be a string")
  result = importType(node["name"].getStr, node["module"].getStr, exported,
    source = node.getOrDefault("source").getStr)
  result.validateTypeImport(description)

proc loadNativeExportConfig*(path: string): NativeExportConfig =
  ## Loads procedure selectors, imported/opaque types, and match policy from JSON.
  let root =
    try:
      parseFile(path)
    except CatchableError as error:
      fail("cannot load native export config " & path & ": " & error.msg)

  root.requireObject("native export config")
  root.rejectUnknownFields(
    ["includeProcs", "excludeProcs", "requireMatches", "typeImports", "opaqueTypes"],
    "native export config",
  )

  var includeSelectors: seq[NativeProcSelector]
  if root.hasKey("includeProcs"):
    let items = root["includeProcs"]
    if items.kind != JArray:
      fail("native export config includeProcs must be an array")
    for item in items.items:
      includeSelectors.add parseSelector(item, "includeProcs", includeSelectors.len)

  var selectors: seq[NativeProcSelector]
  if root.hasKey("excludeProcs"):
    let items = root["excludeProcs"]
    if items.kind != JArray:
      fail("native export config excludeProcs must be an array")
    for item in items.items:
      selectors.add parseSelector(item, "excludeProcs", selectors.len)

  var requireMatches = true
  if root.hasKey("requireMatches"):
    if root["requireMatches"].kind != JBool:
      fail("native export config requireMatches must be a boolean")
    requireMatches = root["requireMatches"].getBool

  var typeImports: seq[NativeTypeImport]
  if root.hasKey("typeImports"):
    let items = root["typeImports"]
    if items.kind != JArray:
      fail("native export config typeImports must be an array")
    for item in items.items:
      typeImports.add parseTypeImport(item, typeImports.len)

  var opaqueTypes: seq[NativeOpaqueType]
  if root.hasKey("opaqueTypes"):
    if root["opaqueTypes"].kind != JArray:
      fail("opaqueTypes must be an array")
    for item in root["opaqueTypes"]:
      item.requireObject("opaqueTypes entry")
      item.rejectUnknownFields(["name", "source"], "opaqueTypes entry")
      if not item.hasKey("name") or item["name"].kind != JString or
          item.hasKey("source") and item["source"].kind != JString:
        fail("opaqueTypes entries require a name and optional source string")
      opaqueTypes.add opaqueType(
        item["name"].getStr, item.getOrDefault("source").getStr
      )

  result = initNativeExportConfig(
    selectors, requireMatches, includeSelectors, typeImports, opaqueTypes
  )
