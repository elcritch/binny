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

  NativeExportConfig* = object
    ## When non-empty, only matching public procedures become exports.
    includeProcs*: seq[NativeProcSelector]
    ## Public procedures removed from the native export surface.
    excludeProcs*: seq[NativeProcSelector]
    ## Raise an error when an inclusion or exclusion matches no public procedure.
    requireMatches*: bool

proc fail(message: string) {.noinline, noreturn.} =
  raise newException(NativeExportConfigError, message)

func excludeProc*(name: string, source = ""): NativeProcSelector =
  ## Selects procedures to exclude by source-relative path and Nim name.
  ## Write quoted names without backticks, for example ``foo=`` or ``for``.
  NativeProcSelector(source: source.replace('\\', '/'), name: name)

func includeProc*(name: string, source = ""): NativeProcSelector =
  ## Selects a public procedure to include by source-relative path and Nim name.
  ## Write quoted names without backticks, for example ``foo=`` or ``for``.
  NativeProcSelector(source: source.replace('\\', '/'), name: name)

proc validateSelector(selector: NativeProcSelector, description: string) =
  if selector.name.len == 0:
    fail(description & " has an empty procedure name")
  if '`' in selector.name:
    fail(description & " names must omit backticks: " & selector.name)
  if selector.source.isAbsolute:
    fail(description & " source must be relative: " & selector.source)

proc validateNativeExportConfig*(config: NativeExportConfig) =
  ## Validates selector spellings before applying an export configuration.
  for selector in config.excludeProcs:
    selector.validateSelector("native export exclusion")
  for selector in config.includeProcs:
    selector.validateSelector("native export inclusion")

proc initNativeExportConfig*(
    excludeProcs: openArray[NativeProcSelector] = [],
    requireMatches = true,
    includeProcs: openArray[NativeProcSelector] = [],
): NativeExportConfig =
  ## Creates a validated native export configuration.
  result.excludeProcs = @excludeProcs
  result.includeProcs = @includeProcs
  result.requireMatches = requireMatches
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
  ## Returns whether a source-relative procedure matches this selector.
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
  node.rejectUnknownFields(["source", "name"], description)
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

proc loadNativeExportConfig*(path: string): NativeExportConfig =
  ## Loads procedure selectors and ``requireMatches`` from a JSON file.
  let root =
    try:
      parseFile(path)
    except CatchableError as error:
      fail("cannot load native export config " & path & ": " & error.msg)

  root.requireObject("native export config")
  root.rejectUnknownFields(
    ["includeProcs", "excludeProcs", "requireMatches"], "native export config"
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

  result = initNativeExportConfig(selectors, requireMatches, includeSelectors)
