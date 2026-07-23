import std/[assertions, os, tempfiles]

import binny/bif_safe

const SampleSymbol = "sample.exported.symbol"

proc tempBifPath(): string =
  let (file, path) = createTempFile("binny-bif-", ".bif")
  file.close()
  result = path

proc writeSample(path: string) =
  var source = createTokenBuf()
  let
    statements = source.tags.registerTag("stmts")
    declaration = source.tags.registerTag("sdef")
  source.buildTree statements:
    source.buildTree declaration:
      source.addSymDef(SampleSymbol)
      source.addIdent("x")
  source.store(path)

proc varintWidth(first: byte): int =
  if first <= 240: 1
  elif first <= 248: 2
  else: int(first) - 246

proc tokenOffset(data: string): int =
  result = 16 # magic plus the fixed-width index offset
  for _ in 0 ..< 5:
    result += varintWidth(byte(data[result]))
  let alignment = sizeof(NifToken)
  result += (alignment - (result and (alignment - 1))) and (alignment - 1)

block owned_load_keeps_cursors_alive_without_the_file:
  let path = tempBifPath()
  defer:
    if fileExists(path):
      removeFile(path)
  writeSample(path)

  var declaration: Cursor
  block:
    var module = load(path)
    doAssert module.index.len == 1
    declaration = module.findDeclaration(SampleSymbol)
    doAssert not declaration.cursorIsNil

  removeFile(path)
  doAssert declaration.kind == TagLit
  doAssert declaration.tags.tagName(declaration.cursorTagId) == "sdef"
  declaration.endRead()

block load_from_file_leaves_the_file_with_the_caller:
  let path = tempBifPath()
  defer: removeFile(path)
  writeSample(path)

  var file = open(path, fmRead)
  var module = loadFromFile(file, path)
  doAssert module.findDeclaration(SampleSymbol).kind == TagLit
  doAssert getFilePos(file) == getFileSize(file)
  close(file)

block valid_queries_use_the_checked_loader:
  let path = tempBifPath()
  defer: removeFile(path)
  writeSample(path)

  doAssert containsSymChecked(path, SampleSymbol)
  doAssert containsSym(path, SampleSymbol)
  doAssert not containsSym(path, "missing.symbol.name")
  doAssert loadIndex(path).len == 1

block truncated_files_are_recoverable_at_every_byte:
  let
    validPath = tempBifPath()
    truncatedPath = tempBifPath()
  defer:
    removeFile(validPath)
    removeFile(truncatedPath)
  writeSample(validPath)
  let contents = readFile(validPath)

  for length in 0 ..< contents.len:
    writeFile(truncatedPath, contents[0 ..< length])
    var
      module: BifModule
      failure: BifLoadFailure
    doAssert not tryLoad(truncatedPath, module, failure)
    doAssert failure.kind in {bekTruncated, bekInvalidIndex, bekInvalidData}
    doAssert failure.path == truncatedPath
    doAssert failure.message.len > 0

block magic_and_version_failures_are_distinct:
  let path = tempBifPath()
  defer: removeFile(path)
  var
    module: BifModule
    failure: BifLoadFailure

  writeFile(path, "NOTBIF!!")
  doAssert not tryLoad(path, module, failure)
  doAssert failure.kind == bekInvalidMagic

  writeFile(path, "NIFBIN\x00\x04")
  doAssert not tryLoad(path, module, failure)
  doAssert failure.kind == bekUnsupportedFormat
  doAssert not containsSym(path, SampleSymbol)
  doAssertRaises BifError:
    discard containsSymChecked(path, SampleSymbol)

block invalid_token_kind_is_rejected_before_cursor_use:
  let path = tempBifPath()
  defer: removeFile(path)
  writeSample(path)
  var contents = readFile(path)
  let offset = tokenOffset(contents)
  contents[offset] = char((ord(contents[offset]) and 0xF0) or 0x0F)
  writeFile(path, contents)

  var
    module: BifModule
    failure: BifLoadFailure
  doAssert not tryLoad(path, module, failure)
  doAssert failure.kind == bekInvalidData

block invalid_index_visibility_is_rejected_without_a_range_defect:
  let path = tempBifPath()
  defer: removeFile(path)
  writeSample(path)
  var contents = readFile(path)
  contents[^1] = char(2)
  writeFile(path, contents)

  var
    module: BifModule
    failure: BifLoadFailure
  doAssert not tryLoad(path, module, failure)
  doAssert failure.kind == bekInvalidIndex

block load_limits_are_reported_without_replacing_a_valid_module:
  let
    validPath = tempBifPath()
    invalidPath = tempBifPath()
  defer:
    removeFile(validPath)
    removeFile(invalidPath)
  writeSample(validPath)
  writeFile(invalidPath, "x")

  var
    module = load(validPath)
    failure: BifLoadFailure
    limits = DefaultBifLoadLimits
  limits.maxFileBytes = 1
  doAssert not tryLoad(validPath, module, failure, limits)
  doAssert failure.kind == bekLimitExceeded
  doAssert module.findDeclaration(SampleSymbol).kind == TagLit

  limits = DefaultBifLoadLimits
  limits.maxTokens = 0
  doAssert not tryLoad(validPath, module, failure, limits)
  doAssert failure.kind == bekLimitExceeded
  doAssert module.findDeclaration(SampleSymbol).kind == TagLit

  doAssert not tryLoad(invalidPath, module, failure)
  doAssert failure.kind == bekTruncated
  doAssert module.findDeclaration(SampleSymbol).kind == TagLit

block missing_file_is_a_recoverable_io_failure:
  let path = getTempDir() / "binny-bif-file-that-does-not-exist.bif"
  if fileExists(path):
    removeFile(path)
  var
    module: BifModule
    failure: BifLoadFailure
  doAssert not tryLoad(path, module, failure)
  doAssert failure.kind == bekIo
  doAssert failure.path == path
