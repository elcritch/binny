## Checked, owned BIF loading for long-lived tools.
##
## Unlike `bif.load`, this module does not memory-map token storage. It copies
## the token block, validates the complete file, and closes files it opens before
## returning. Malformed input raises `BifError`; `tryLoad` provides a
## non-raising boundary for workspace scans.

when defined(nimony):
  {.feature: "lenientnils".}

import std/[syncio, varints]
import ./bif except containsSym, load, loadFromFile, loadIndex, loadIndexFromFile
import ./nifcore

export bif except containsSym, load, loadFromFile, loadIndex, loadIndexFromFile

include compat2

const
  Version = 5'u8
  MagicLen = 8
  LittleEndianTag = 0'u8

type
  BifErrorKind* = enum ## Stable categories for recoverable BIF failures.
    bekIo,                ## The file could not be opened, read, or closed.
    bekTruncated,         ## The file ended before a complete value was read.
    bekInvalidMagic,      ## The input is not a BIF file.
    bekUnsupportedFormat, ## The endianness or BIF version is unsupported.
    bekInvalidData,       ## A header, pool, or token stream is malformed.
    bekInvalidIndex,      ## The symbol index contains invalid metadata.
    bekLimitExceeded      ## Input exceeds a configured resource limit.
  BifError* = object of CatchableError ## Recoverable BIF load exception.
    kind*: BifErrorKind ## Stable failure category.
    path*: string       ## File path or caller-supplied source description.
    offset*: int64      ## Byte offset of the failure, or `-1` when unavailable.
  BifLoadLimits* = object ## Allocation limits for checked BIF loading.
    maxFileBytes*: int64  ## Maximum encoded file size.
    maxTokens*: int       ## Maximum number of `NifToken` words.
    maxPoolEntries*: int  ## Maximum entries in each string-like pool.
    maxStringBytes*: int  ## Maximum encoded length of one pool string.
    maxIndexEntries*: int ## Maximum declaration-index entries.
  BifLoadFailure* = object ## Copyable diagnostic produced by `tryLoad`.
    kind*: BifErrorKind ## Stable failure category.
    path*: string       ## Path passed to `tryLoad`.
    offset*: int64      ## Byte offset of the failure, or `-1` when unavailable.
    message*: string    ## Human-readable diagnostic with path and offset.

const
  DefaultBifLoadLimits* = BifLoadLimits( ## Conservative daemon-safe limits.
    maxFileBytes: 1024'i64 * 1024 * 1024,
    maxTokens: 128 * 1024 * 1024,
    maxPoolEntries: 4 * 1024 * 1024,
    maxStringBytes: 256 * 1024 * 1024,
    maxIndexEntries: 16 * 1024 * 1024,
  )

proc magic(): array[MagicLen, char] =
  result = ['N', 'I', 'F', 'B', 'I', 'N', char(LittleEndianTag), char(Version)]

proc failBif(kind: BifErrorKind; path: string; offset: int64;
             detail: string) {.noinline, noreturn.} =
  var message = "bif"
  if path.len > 0:
    message.add " " & path
  if offset >= 0:
    message.add " at byte " & $offset
  message.add ": " & detail
  when defined(nimony):
    quit message
  else:
    var error = newException(BifError, message)
    error.kind = kind
    error.path = path
    error.offset = offset
    raise error

proc varintLen(b0: byte): int =
  if b0 <= 240: 1
  elif b0 <= 248: 2
  else: int(b0) - 246

proc tokenPad(pos: int): int =
  ## Number of zero bytes to insert after the (variable-width varint) header so
  ## the token block begins `NifToken`-aligned. The mmap loader borrows that block
  ## in place and `adoptForeignTokens` asserts it is aligned; the fixed-header
  ## format got this for free, but a varint header can end on any byte. Writer and
  ## every reader compute this from the SAME post-header position, so they agree.
  let a = sizeof(NifToken)
  (a - (pos and (a - 1))) and (a - 1)

type CheckedBifReader = object
  file: File
  path: string
  position: int64
  size: int64
  limits: BifLoadLimits

proc validateLimits(limits: BifLoadLimits; path: string) =
  if limits.maxFileBytes < 0 or limits.maxTokens < 0 or
      limits.maxPoolEntries < 0 or limits.maxStringBytes < 0 or
      limits.maxIndexEntries < 0:
    failBif(bekLimitExceeded, path, -1,
      "BIF load limits must be non-negative")

proc initCheckedBifReader(f: File; path: string;
                          limits: BifLoadLimits): CheckedBifReader =
  validateLimits(limits, path)
  result = CheckedBifReader(file: f, path: path, limits: limits)
  result.position = onRaiseQuit getFilePos(f)
  result.size = onRaiseQuit getFileSize(f)
  if result.position != 0:
    failBif(bekInvalidData, path, result.position,
      "BIF reading must start at byte zero")
  if result.size < 0:
    failBif(bekIo, path, -1, "could not determine file size")
  if result.size > limits.maxFileBytes:
    failBif(bekLimitExceeded, path, 0,
      "file size " & $result.size & " exceeds limit " & $limits.maxFileBytes)

proc remaining(r: CheckedBifReader): int64 {.inline.} =
  r.size - r.position

proc requireAvailable(r: CheckedBifReader; count: int64; detail: string) =
  if count < 0 or count > r.remaining:
    failBif(bekTruncated, r.path, r.position, detail)

proc readExact(r: var CheckedBifReader; data: pointer; count: int;
               detail: string) =
  r.requireAvailable(int64(count), detail)
  if count > 0:
    let got = onRaiseQuit r.file.readBuffer(data, count)
    if got != count:
      failBif(bekTruncated, r.path, r.position, detail)
  r.position += int64(count)

proc readU64(r: var CheckedBifReader; detail: string): uint64 =
  result = 0'u64
  r.readExact(addr result, sizeof(result), detail)

proc readVarint(r: var CheckedBifReader; detail: string): uint64 =
  var bytes = default(array[maxVarIntLen, byte])
  r.readExact(addr bytes[0], 1, detail)
  let count = varintLen(bytes[0])
  if count > 1:
    r.readExact(addr bytes[1], count - 1, detail)
  if readVu64(bytes.toOpenArray(0, count - 1), result) != count:
    failBif(bekInvalidData, r.path, r.position - int64(count),
      "invalid " & detail)

proc readCount(r: var CheckedBifReader; detail: string; limit: int): int =
  let offset = r.position
  let raw = r.readVarint(detail)
  if raw > uint64(high(int)):
    failBif(bekInvalidData, r.path, offset, detail & " does not fit in int")
  result = int(raw)
  if result > limit:
    failBif(bekLimitExceeded, r.path, offset,
      detail & " " & $result & " exceeds limit " & $limit)

proc readString(r: var CheckedBifReader): string =
  let count = r.readCount("string length", r.limits.maxStringBytes)
  r.requireAvailable(int64(count), "truncated string")
  result = newString(count)
  if count > 0:
    r.readExact(cast[pointer](beginStore(result, count)), count,
      "truncated string")
    endStore(result)

proc checkMagic(r: var CheckedBifReader) =
  var found = default(array[MagicLen, char])
  r.readExact(addr found[0], MagicLen, "truncated magic")
  let expected = magic()
  for i in 0 ..< 6:
    if found[i] != expected[i]:
      failBif(bekInvalidMagic, r.path, 0, "not a BIF file")
  if found[6] != expected[6] or found[7] != expected[7]:
    failBif(bekUnsupportedFormat, r.path, 6,
      "unsupported endianness or BIF version")

proc checkedTokenBytes(r: CheckedBifReader; tokenCount: int): int =
  if tokenCount > high(int) div sizeof(NifToken):
    failBif(bekLimitExceeded, r.path, r.position,
      "token block size overflows int")
  result = tokenCount * sizeof(NifToken)

proc combinedPayloadChecked(tokens: ptr UncheckedArray[NifToken]; head: int;
                            extensionCount: int; path: string;
                            tokenOffset: int64): uint64 =
  result = uint64(uint32(tokens[head]) shr KindBits)
  var shift = int(PayloadBits)
  for i in 0 ..< extensionCount:
    let part = uint64(uint32(tokens[head + 1 + i]) shr KindBits)
    if shift >= 64 or part > (high(uint64) shr shift):
      failBif(bekInvalidData, path,
        tokenOffset + int64(head + 1 + i) * sizeof(NifToken),
        "token payload exceeds 64 bits")
    result = result or (part shl shift)
    shift += int(PayloadBits)

proc validatePoolReference(id: uint64; poolLength: int; path: string;
                           offset: int64; detail: string) =
  if id == 0 or id > uint64(poolLength):
    failBif(bekInvalidData, path, offset,
      detail & " pool id " & $id & " is out of range")

proc validateTokens(buf: TokenBuf; path: string; tokenOffset: int64) =
  if buf.len == 0:
    return
  let tokens = cast[ptr UncheckedArray[NifToken]](buf.rawTokenPtr)
  let tokenCount = buf.len
  var
    position = 0
    scopeEnds = @[tokenCount]

  template tokenKind(index: int): uint32 =
    uint32(tokens[index]) and KindMask

  template byteOffset(index: int): int64 =
    tokenOffset + int64(index) * sizeof(NifToken)

  while scopeEnds.len > 0:
    while scopeEnds.len > 0 and position == scopeEnds[^1]:
      scopeEnds.setLen(scopeEnds.len - 1)
    if scopeEnds.len == 0:
      break
    let scopeEnd = scopeEnds[^1]
    if position > scopeEnd:
      failBif(bekInvalidData, path, byteOffset(position),
        "token exceeds its enclosing tag")

    let kind = tokenKind(position)
    if kind > uint32(ord(high(NifKind))):
      failBif(bekInvalidData, path, byteOffset(position),
        "unknown token kind " & $kind)
    if kind == uint32(ord(ExtendedSuffix)) or
        kind == uint32(ord(LineInfoLit)):
      failBif(bekInvalidData, path, byteOffset(position),
        "suffix token has no preceding value")

    let head = position
    var nextPosition = position + 1
    while nextPosition < scopeEnd and
        tokenKind(nextPosition) == uint32(ord(ExtendedSuffix)):
      inc nextPosition
    let extensionCount = nextPosition - head - 1

    case int(kind)
    of ord(IntLit), ord(UIntLit), ord(FloatLit):
      if extensionCount > 2:
        failBif(bekInvalidData, path, byteOffset(head),
          "numeric token has too many extension words")
    of ord(StrLit), ord(Ident), ord(Symbol), ord(SymbolDef):
      let payload = uint32(tokens[head]) shr KindBits
      if (payload and StrInlineFlag) != 0'u32:
        if extensionCount != 0:
          failBif(bekInvalidData, path, byteOffset(head),
            "inline string token has an extension word")
      else:
        if extensionCount > 1:
          failBif(bekInvalidData, path, byteOffset(head),
            "pool reference has too many extension words")
        let id = combinedPayloadChecked(tokens, head, extensionCount,
          path, tokenOffset) shr 1
        if kind == uint32(ord(Symbol)) or kind == uint32(ord(SymbolDef)):
          validatePoolReference(id, buf.pool.syms.len, path,
            byteOffset(head), "symbol")
        else:
          validatePoolReference(id, buf.pool.strings.len, path,
            byteOffset(head), "string")
    of ord(TagLit):
      if extensionCount > 1:
        failBif(bekInvalidData, path, byteOffset(head),
          "tag jump has too many extension words")
      let tagId = (uint32(tokens[head]) shr TagShift) and TagMask
      validatePoolReference(uint64(tagId), buf.tags.tags.len, path,
        byteOffset(head), "tag")
    of ord(DotToken):
      if extensionCount != 0 or uint32(tokens[head]) != uint32(DotToken):
        failBif(bekInvalidData, path, byteOffset(head),
          "invalid dot token")
    of ord(CharLit):
      if extensionCount != 0 or
          (uint32(tokens[head]) shr KindBits) > uint32(high(char)):
        failBif(bekInvalidData, path, byteOffset(head),
          "invalid character token")
    else:
      discard

    if extensionCount == 2:
      let highPart = uint32(tokens[head + 2]) shr KindBits
      if highPart > 0xFF'u32:
        failBif(bekInvalidData, path, byteOffset(head + 2),
          "token payload exceeds 64 bits")

    if nextPosition < scopeEnd and
        tokenKind(nextPosition) == uint32(ord(LineInfoLit)):
      let lineInfoPosition = nextPosition
      inc nextPosition
      while nextPosition < scopeEnd and
          tokenKind(nextPosition) == uint32(ord(ExtendedSuffix)):
        inc nextPosition
      let lineExtensions = nextPosition - lineInfoPosition - 1
      if lineExtensions > 3:
        failBif(bekInvalidData, path, byteOffset(lineInfoPosition),
          "line information has too many extension words")

      let linePayload = uint64(uint32(tokens[lineInfoPosition]) shr KindBits)
      var fileId: uint64
      if lineExtensions == 0:
        fileId = (linePayload shr LiColBitsC) and uint64(LiFileMaxC)
      else:
        let highPart = uint64(uint32(tokens[lineInfoPosition + 1]) shr KindBits)
        let combined = linePayload or (highPart shl PayloadBits)
        fileId = (combined shr 10'u64) and 0x3FFF'u64
      if fileId != 0 and fileId > uint64(buf.pool.filenames.len):
        failBif(bekInvalidData, path, byteOffset(lineInfoPosition),
          "line information file id " & $fileId & " is out of range")

      if lineExtensions >= 2:
        var commentId = uint64(
          uint32(tokens[lineInfoPosition + 2]) shr KindBits)
        if lineExtensions == 3:
          let highPart = uint64(
            uint32(tokens[lineInfoPosition + 3]) shr KindBits)
          if highPart > 0xF'u64:
            failBif(bekInvalidData, path, byteOffset(lineInfoPosition + 3),
              "line information comment id exceeds 32 bits")
          commentId = commentId or (highPart shl PayloadBits)
        if commentId != 0 and commentId > uint64(buf.pool.strings.len):
          failBif(bekInvalidData, path, byteOffset(lineInfoPosition),
            "line information comment id " & $commentId & " is out of range")

    if nextPosition > scopeEnd:
      failBif(bekInvalidData, path, byteOffset(head),
        "token suffix crosses its enclosing tag")

    if kind == uint32(ord(TagLit)):
      let jump = combinedPayloadChecked(tokens, head, extensionCount,
        path, tokenOffset) shr TagBits
      if jump > uint64(scopeEnd - nextPosition):
        failBif(bekInvalidData, path, byteOffset(head),
          "tag jump exceeds its enclosing token range")
      position = nextPosition
      if jump > 0:
        scopeEnds.add(position + int(jump))
    else:
      position = nextPosition

proc readIndex(r: var CheckedBifReader; tokenCount, symbolCount: int):
    seq[IndexEntry] =
  let countOffset = r.position
  let count = r.readCount("index entry count", r.limits.maxIndexEntries)
  if int64(count) > r.remaining div 3:
    failBif(bekTruncated, r.path, countOffset, "truncated symbol index")
  result = newSeq[IndexEntry](count)
  for i in 0 ..< count:
    let entryOffset = r.position
    let rawSym = r.readVarint("index symbol id")
    let rawPosition = r.readVarint("index token position")
    let rawVisibility = r.readVarint("index visibility")
    if rawSym == 0 or rawSym > uint64(symbolCount):
      failBif(bekInvalidIndex, r.path, entryOffset,
        "index symbol id " & $rawSym & " is out of range")
    if rawPosition >= uint64(tokenCount) or
        rawPosition > uint64(high(int32)):
      failBif(bekInvalidIndex, r.path, entryOffset,
        "index token position " & $rawPosition & " is out of range")
    if rawVisibility > uint64(ord(high(IndexVis))):
      failBif(bekInvalidIndex, r.path, entryOffset,
        "invalid index visibility " & $rawVisibility)
    result[i] = IndexEntry(
      sym: SymId(uint32(rawSym)),
      pos: int32(rawPosition),
      vis: IndexVis(int(rawVisibility)),
    )

proc validateIndex(module: BifModule; path: string; tokenOffset: int64) =
  if module.index.len == 0:
    return
  let tokens = cast[ptr UncheckedArray[NifToken]](module.buf.rawTokenPtr)
  for entry in module.index:
    let position = int(entry.pos)
    let kind = uint32(tokens[position]) and KindMask
    if kind != uint32(ord(TagLit)):
      failBif(bekInvalidIndex, path,
        tokenOffset + int64(position) * sizeof(NifToken),
        "indexed declaration does not point at a tag")

proc loadFromFile*(f: File; path = "<file>";
                   limits = DefaultBifLoadLimits): BifModule =
  ## Read and validate an owned `BifModule` from an already-open binary file.
  ## The file must be positioned at byte zero and remains owned by the caller.
  ## Malformed input raises `BifError`; ordinary I/O errors remain catchable.
  var r = initCheckedBifReader(f, path, limits)
  r.checkMagic()
  let indexOffset = r.readU64("truncated index offset")
  let tokenCount = r.readCount("token count", limits.maxTokens)
  let nTags = r.readCount("tag pool count", min(limits.maxPoolEntries, int(TagMask)))
  let nStrings = r.readCount("string pool count", limits.maxPoolEntries)
  let nSyms = r.readCount("symbol pool count", limits.maxPoolEntries)
  let nFiles = r.readCount("filename pool count", limits.maxPoolEntries)

  if indexOffset > uint64(high(int64)) or indexOffset >= uint64(r.size):
    failBif(bekInvalidIndex, path, MagicLen,
      "index offset " & $indexOffset & " is outside the file")

  let pad = tokenPad(int(r.position))
  if pad > 0:
    var padding = default(array[sizeof(NifToken), byte])
    let padOffset = r.position
    r.readExact(addr padding[0], pad, "truncated token alignment padding")
    for i in 0 ..< pad:
      if padding[i] != 0:
        failBif(bekInvalidData, path, padOffset + int64(i),
          "non-zero token alignment padding")

  let tokenOffset = r.position
  let tokenBytes = r.checkedTokenBytes(tokenCount)
  r.requireAvailable(int64(tokenBytes), "truncated token block")
  result = BifModule()
  result.buf = createTokenBuf(max(tokenCount, 16))
  if tokenCount > 0:
    let destination = result.buf.growRawUninit(tokenCount)
    r.readExact(destination, tokenBytes, "truncated token block")

  let minimumPoolBytes = int64(nTags) + int64(nStrings) + int64(nSyms) +
    int64(nFiles)
  if minimumPoolBytes + 1 > r.remaining:
    failBif(bekTruncated, path, r.position, "truncated BIF pools")

  for i in 1 .. nTags:
    let id = result.buf.tags.tags.getOrIncl(r.readString())
    if uint32(id) != uint32(i):
      failBif(bekInvalidData, path, r.position, "duplicate tag pool entry")
  for i in 1 .. nStrings:
    let id = result.buf.pool.strings.getOrIncl(r.readString())
    if uint32(id) != uint32(i):
      failBif(bekInvalidData, path, r.position, "duplicate string pool entry")
  for i in 1 .. nSyms:
    let id = result.buf.pool.syms.getOrIncl(r.readString())
    if uint32(id) != uint32(i):
      failBif(bekInvalidData, path, r.position, "duplicate symbol pool entry")
  for i in 1 .. nFiles:
    let id = result.buf.pool.filenames.getOrIncl(r.readString())
    if uint32(id) != uint32(i):
      failBif(bekInvalidData, path, r.position, "duplicate filename pool entry")

  if indexOffset != uint64(r.position):
    failBif(bekInvalidIndex, path, r.position,
      "index offset does not match the end of the token pools")
  result.index = r.readIndex(tokenCount, nSyms)
  if r.position != r.size:
    failBif(bekInvalidData, path, r.position, "unexpected trailing data")
  validateTokens(result.buf, path, tokenOffset)
  validateIndex(result, path, tokenOffset)

proc load*(filename: string;
           limits = DefaultBifLoadLimits): BifModule =
  ## Load a BIF into owned memory and validate it before returning. This is the
  ## safe default for long-lived processes: no file or mapping remains open.
  when defined(nimony):
    var f = onRaiseQuit open(filename, fmRead)
    try:
      result = loadFromFile(f, filename, limits)
    finally:
      onRaiseQuit close(f)
  else:
    var f = default(File)
    try:
      if not open(f, filename, fmRead):
        failBif(bekIo, filename, -1, "could not open file")
      try:
        result = loadFromFile(f, filename, limits)
      finally:
        close(f)
    except BifError:
      raise
    except CatchableError:
      failBif(bekIo, filename, -1, getCurrentExceptionMsg())

when not defined(nimony):
  proc tryLoad*(filename: string; loaded: var BifModule;
                failure: var BifLoadFailure;
                limits = DefaultBifLoadLimits): bool {.raises: [].} =
    ## Non-raising workspace-scan boundary. On failure `loaded` is unchanged and
    ## `failure` contains a copyable diagnostic; on success `failure` is cleared.
    try:
      var candidate = load(filename, limits)
      loaded = move(candidate)
      failure = default(BifLoadFailure)
      result = true
    except BifError as error:
      failure = BifLoadFailure(
        kind: error.kind,
        path: error.path,
        offset: error.offset,
        message: error.msg,
      )
      result = false

proc loadIndexFromFile*(f: File; path = "<file>";
                        limits = DefaultBifLoadLimits): seq[IndexEntry] =
  ## Load a validated BIF and return its symbol index. The returned symbol ids
  ## are meaningful only together with the module's symbol pool, so most callers
  ## should retain the complete `BifModule` instead.
  var module = loadFromFile(f, path, limits)
  result = move(module.index)

proc loadIndex*(filename: string;
                limits = DefaultBifLoadLimits): seq[IndexEntry] =
  ## Load a validated BIF and return its symbol index.
  var module = load(filename, limits)
  result = move(module.index)

proc containsSymChecked*(filename, name: string;
                         limits = DefaultBifLoadLimits): bool =
  ## Return whether the validated BIF's symbol pool contains `name`.
  var module = load(filename, limits)
  for i in 1 .. module.buf.pool.syms.len:
    if poolSym(module.buf.pool, SymId(i)) == name:
      return true

proc containsSym*(filename, name: string;
                  limits = DefaultBifLoadLimits): bool {.raises: [].} =
  ## Non-raising membership probe. Missing, unreadable, incompatible, or
  ## malformed files all return `false`; use `containsSymChecked` when the
  ## failure reason should be reported.
  when defined(nimony):
    result = containsSymChecked(filename, name, limits)
  else:
    try:
      result = containsSymChecked(filename, name, limits)
    except BifError:
      result = false

