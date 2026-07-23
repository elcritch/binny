#       Nif library
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## bif — **B**inary N**IF**: direct binary load/store of a `nifcore.TokenBuf`.
##
## NIF on disk is a *textual* s-expression format: great for tooling, diffing and
## bootstrapping, but for a compiler **cache** the text is pure overhead. Loading
## a text NIF means a full tokenizer/parser pass, and the text is several times
## larger than the in-memory token stream — e.g. a Nimbus module measured at
## 890 MiB of text collapses to a 176 MiB `TokenBuf` (0.20×), of which 99.5 % is
## the flat `uint32` token array and < 1 MiB is the (already deduped) string
## pools. `bif` writes exactly that in-memory representation to disk and reads it
## straight back, so a cache load is one `readBuffer` of the token block plus a
## quick re-intern of the small pools — no parsing.
##
## Layout. A `.bif` file is stored **little-endian**: the token block and the
## `indexOffset` are raw host-endian dumps and BIF is *defined* to be
## little-endian (every supported target is), so the `Magic` carries a fixed
## endianness byte (`0` = little) plus a version, and a mismatched/foreign file is
## rejected rather than misread. The host word size does NOT appear — a token is
## always `uint32`. Every integer is a SQLite-style `varint`
## (`std/varints`) — most counts and lengths are small, so the header and the
## per-string/-entry length prefixes shrink to a byte or two. The SOLE exception
## is `indexOffset`, which is a **fixed 8-byte** little integer: it is written as
## a placeholder and patched in place once the tail offset is known, so it must
## keep a constant width (a varint would change size when patched):
##
## ```
##   Magic            8 bytes  ("NIFBIN" + endianness byte (0=little) + Version)
##   indexOffset      u64      -- FIXED 8 bytes; BYTE offset of the index (patched)
##   tokenCount       varint
##   nTags            varint
##   nStrings         varint
##   nSyms            varint
##   nFiles           varint
##   pad              0..3 zero bytes  -- align the token block to NifToken (4 B)
##   tokens           tokenCount * sizeof(NifToken)   -- one raw block
##   tags             nTags    * (varint len + bytes)
##   strings          nStrings * (varint len + bytes)
##   syms             nSyms    * (varint len + bytes)
##   filenames        nFiles   * (varint len + bytes)
##   index (@indexOffset)
##     nIndex         varint
##     entries        nIndex   * (varint symId, varint tokenPos, varint vis)
## ```
##
## The `index` is the binary analogue of a text NIF's embedded `(.index …)`:
## global `SymbolDef` -> declaration token position + visibility, so a loaded
## buffer can locate one symbol without scanning. It is ALWAYS present (a cache
## with no index would force a full rescan to find any declaration) and lives at
## the **end** of the file, exactly like the text format's trailing index. The
## single `indexOffset` header field is the binary `(.indexat …)`: the fixed
## 8-byte slot a reader follows to jump straight to the index. Because the offset
## is only known once the token block and pools have been written, `storeToFile`
## writes a placeholder, streams everything, then patches the slot — mirroring the
## text writer's `addHeader27` reservation + `patchIndexAt`. It stays a constant
## width precisely so that in-place patch keeps working. The index entries
## themselves are gathered in the single forward token traversal `buildIndex`,
## the way the text writer accumulates `(.index …)` entries while emitting tokens.
##
## The token block is stored verbatim. Every pool-referencing token embeds a
## *pool id* — `StrLit`/`Symbol`/`SymbolDef`/`Ident` (strings/syms id),
## `LineInfoLit` (a `FileId`) and `TagLit` (a 9-bit tag id) — and `nifcore`
## assigns those ids 1, 2, … in intern order. The pools are written in that same
## id order and re-interned in order on load, reproducing identical ids, so the
## raw token words stay valid **without any patching**.
##
## INVARIANT (important): that zero-patch property holds *only* because the load
## interns into **empty, freshly minted** pools, so the first `getOrIncl` returns
## id 1 again. `bif` therefore never loads into a shared/pre-populated pool: doing
## so would assign different ids to the same strings while the token words still
## carry the old ids — silent corruption. Cross-module pool sharing would require
## remapping every pool-referencing token, which defeats the whole point. If you
## need a buffer to share a pool with others, load it with `bif` first and then
## copy across pools via `nifcore.addSubtree` (which re-interns properly).

when defined(nimony):
  {.feature: "lenientnils".}

import std / [syncio, assertions, strutils, varints]
import nifcore
import vfs

include compat2   # `onRaiseQuit`: run a raising call and `quit` on failure; identity under Nim

# Bulk string data access. Under Nimony these come from `system`; a `string`'s
# payload cannot be reached with a bare `addr s[0]` (it may be inline-stored), so
# reads go through `readRawData` and bulk writes through `beginStore`/`endStore`.
# Host Nim has no such API, so shim it (guarded, matching `stringviews.nim`).
when not defined(nimony):
  when not declared(readRawData):
    proc readRawData*(s: string): ptr UncheckedArray[char] {.inline.} =
      if s.len == 0: nil
      else: cast[ptr UncheckedArray[char]](addr(s[0]))
  when not declared(beginStore):
    proc beginStore*(s: var string; newLen: int; start = 0): ptr UncheckedArray[char] {.inline.} =
      s.setLen(newLen)
      if s.len == 0: nil
      else: cast[ptr UncheckedArray[char]](addr(s[start]))
  when not declared(endStore):
    proc endStore*(s: var string) {.inline.} = discard

const
  Version = 5'u8
  MagicLen = 8
  LittleEndianTag = 0'u8
    ## Endianness marker in the `Magic`. BIF stores the token block and the
    ## `indexOffset` as raw host-endian bytes and is *defined* to be
    ## little-endian (every supported target is), so this byte is fixed at 0 =
    ## little. It replaces a former `sizeof(int)` byte that guarded nothing: a
    ## token is always `uint32`, so the host word size never affects the layout.

# ── embedded index ──────────────────────────────────────────────────────────
# A text NIF carries a trailing `(.index …)` mapping every *global* `SymbolDef`
# to the BYTE offset of its declaration, so a reader can seek straight to one
# symbol without scanning. Byte offsets are meaningless in the binary token
# world, so `bif` persists its OWN index: each global symbol's SymId, the TOKEN
# POSITION of its declaration's enclosing tag, and its visibility. This is what
# lets a `bif`-loaded buffer back an on-demand symbol loader (no full scan).

type
  IndexVis* = enum ## Import visibility recorded for an indexed declaration.
    ivHidden,    ## not importable as a bare identifier (the `.` marker)
    ivExported   ## importable (`x` marker)
  IndexEntry* = object ## One global declaration in a BIF symbol index.
    sym*: SymId    ## the global symbol (resolve its name via `buf.pool.syms`)
    pos*: int32    ## token index of the declaration's enclosing tag
    vis*: IndexVis
  BifModule* = object ## A loaded BIF token buffer and its symbol index.
    buf*: TokenBuf
    index*: seq[IndexEntry]
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

proc findDeclaration*(module: var BifModule; name: string): Cursor =
  ## Returns the indexed declaration for ``name``, or a nil cursor when absent.
  result = default(Cursor)
  for entry in module.index:
    if poolSym(module.buf.pool, entry.sym) == name:
      return module.buf.cursorAt(entry.pos)

iterator declarations*(module: var BifModule):
    tuple[name: string, visibility: IndexVis, declaration: Cursor] =
  ## Iterates all indexed global declarations in storage order.
  for entry in module.index:
    yield (poolSym(module.buf.pool, entry.sym), entry.vis,
      module.buf.cursorAt(entry.pos))

proc isGlobalSymbol(s, dottedSuffix: string): bool =
  ## Mirror of `nifbuilder.addSymbolDefRetIsGlobal`: a symbol is "global" (gets
  ## an index entry) when its name — with a self-module `dottedSuffix` compressed
  ## to a single trailing dot — has >= 2 dots (`addSymbolImpl` counts dots from
  ## index 1).
  var lim = s.len
  if dottedSuffix.len > 0 and s.endsWith(dottedSuffix):
    lim = s.len - dottedSuffix.len + 1
  if lim > s.len: lim = s.len
  var dots = 0
  for i in 1 ..< lim:
    if s[i] == '.': inc dots
  dots >= 2

proc buildIndex*(b: var TokenBuf; dottedSuffix = ""): seq[IndexEntry] =
  ## Scan `b` for global `SymbolDef`s and record, for each, its SymId, the token
  ## position of the most-recently-opened tag (the declaration's `(`, mirroring
  ## `nifcoreparse.toModuleString`'s `mostRecentOffset`), and its visibility
  ## (hidden when the marker after the def is a `DotToken`, else exported).
  result = @[]
  if b.len == 0: return
  var c = b.beginRead()
  var mostRecentTagPos = 0'i32
  while c.hasMore:
    case c.kind
    of TagLit:
      mostRecentTagPos = int32 cursorToPosition(b, c)
      inc c                          # descend into the body (visit every token)
    of SymbolDef:
      let isG = isGlobalSymbol(symName(c), dottedSuffix)
      let sid = c.symId
      let tagPos = mostRecentTagPos
      inc c                          # advance to the marker / next sibling
      if isG:
        let vis = if c.hasMore and c.kind == DotToken: ivHidden else: ivExported
        result.add IndexEntry(sym: sid, pos: tagPos, vis: vis)
    else:
      inc c
  c.endRead()

proc magic(): array[MagicLen, char] =
  result = ['N', 'I', 'F', 'B', 'I', 'N', char(LittleEndianTag), char(Version)]

# Under Nimony the compiler-facing writer remains non-raising. Host-Nim readers
# use the checked reader below and report malformed input through `BifError`.
proc getPos(f: File): int64 = onRaiseQuit getFilePos(f)
proc setPos(f: File; pos: int64) = onRaiseQuit setFilePos(f, pos)
proc setPosEnd(f: File) = onRaiseQuit setFilePos(f, 0, fspEnd)

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

proc writeExact(f: File; p: pointer; n: int) =
  let written = onRaiseQuit f.writeBuffer(p, n)
  assert written == n

# `indexOffset` is the one fixed-width field: a placeholder that gets patched in
# place, so it must always occupy exactly 8 bytes (a varint would resize on patch).
proc writeU64(f: File; x: uint64) =
  var v = x
  writeExact(f, addr v, 8)

# Everything else is a varint. `varintLen` recovers a varint's total byte length
# from its first byte (mirrors `readVu64`'s `int(z[0]-246)` length check), so a
# file reader can pull the first byte, then the remaining `n-1`, then decode.
proc varintLen(b0: byte): int =
  if b0 <= 240: 1
  elif b0 <= 248: 2
  else: int(b0) - 246

proc writeVarint(f: File; x: uint64) =
  var buf = default(array[maxVarIntLen, byte])
  let n = writeVu64(buf, x)
  writeExact(f, addr buf[0], n)

proc writeStr(f: File; s: string) =
  writeVarint(f, uint64 s.len)
  if s.len > 0:
    writeExact(f, cast[pointer](readRawData(s)), s.len)

proc tokenPad(pos: int): int =
  ## Number of zero bytes to insert after the (variable-width varint) header so
  ## the token block begins `NifToken`-aligned. The mmap loader borrows that block
  ## in place and `adoptForeignTokens` asserts it is aligned; the fixed-header
  ## format got this for free, but a varint header can end on any byte. Writer and
  ## every reader compute this from the SAME post-header position, so they agree.
  let a = sizeof(NifToken)
  (a - (pos and (a - 1))) and (a - 1)

# ── store ─────────────────────────────────────────────────────────────────

proc storeToFile*(b: var TokenBuf; f: File; dottedSuffix = "") =
  ## Write `b` (token stream + pools + symbol index) to an already-open binary
  ## file. The pools are written whole, in id order. If `b` shares a pool with
  ## other buffers, the *entire* shared pool is written (still correct — ids stay
  ## dense and load reproduces them — but larger than this module needs). For a
  ## compact, self-contained cache file, build the buffer against its own private
  ## pool. `dottedSuffix` is the self-module suffix used to decide which symbols
  ## are global (it gets the same compression as the text writer).
  # The index is built in a single forward traversal of the token stream and is
  # always emitted — see the module doc.
  let index = buildIndex(b, dottedSuffix)
  var m = magic()
  writeExact(f, addr m[0], MagicLen)
  # Reserve the `indexOffset` slot. We can only fill it once tokens and pools are
  # written, so write a placeholder now and patch it at the end — the binary
  # equivalent of `addHeader27`'s `(.indexat …)` reservation + `patchIndexAt`.
  let indexAtPos = getPos(f)
  writeU64(f, 0'u64)                   # fixed 8-byte placeholder for indexOffset
  writeVarint(f, uint64 b.len)
  writeVarint(f, uint64 b.tags.tags.len)
  writeVarint(f, uint64 b.pool.strings.len)
  writeVarint(f, uint64 b.pool.syms.len)
  writeVarint(f, uint64 b.pool.filenames.len)
  # Pad to NifToken alignment so the mmap loader can borrow the token block in
  # place (see `tokenPad`).
  let pad = tokenPad(int getPos(f))
  if pad > 0:
    var zeros = default(array[8, byte])
    writeExact(f, addr zeros[0], pad)
  # token stream: one contiguous block.
  let bytes = b.len * sizeof(NifToken)
  if bytes > 0:
    writeExact(f, b.rawTokenPtr, bytes)
  # pools, each in id order (ids are 1-based, dense up to len).
  for i in 1 .. b.tags.tags.len:      writeStr(f, b.tags.tags[TagId(i)])
  for i in 1 .. b.pool.strings.len:   writeStr(f, b.pool.strings[StrId(i)])
  for i in 1 .. b.pool.syms.len:      writeStr(f, b.pool.syms[SymId(i)])
  for i in 1 .. b.pool.filenames.len: writeStr(f, b.pool.filenames[FileId(i)])
  # symbol index — self-contained at the offset we now know. `pos` is a token
  # index (always >= 0) and `vis` a 0/1 enum, so plain varints suffice.
  let indexOffset = getPos(f)
  writeVarint(f, uint64 index.len)
  for e in index:
    writeVarint(f, uint64 e.sym)
    writeVarint(f, uint64 e.pos)
    writeVarint(f, uint64 ord(e.vis))
  # Patch the fixed-width header slot to point at the index, then leave the
  # cursor at EOF. The slot is 8 bytes wide, so this overwrites exactly it.
  setPos(f, indexAtPos)
  writeU64(f, uint64 indexOffset)
  setPosEnd(f)

proc store*(b: var TokenBuf; filename: string; dottedSuffix = "") =
  ## Write `b` to `filename` in binary `.bif` form (with its symbol index).
  var f = open(filename, fmWrite)
  storeToFile(b, f, dottedSuffix)
  close(f)

# ── load ──────────────────────────────────────────────────────────────────

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

# ── mmap-backed load (zero-copy token block) ────────────────────────────────
# `loadMappedProcessLifetime` maps the whole `.bif` and BORROWS its token block.
# It intentionally never releases the mapping or the freshly interned pools, so
# it is only suitable for short-lived compiler workers. Long-lived applications
# must use the checked, owned `load` above.

type
  BifReader = object
    base: uint     # start of the mapped bytes
    pos: int       # cursor within [0, size)
    size: int

proc rU64(r: var BifReader): uint64 =
  assert r.pos + 8 <= r.size, "bif: truncated header"
  result = cast[ptr uint64](r.base + uint(r.pos))[]
  r.pos += 8

proc rVarint(r: var BifReader): uint64 =
  assert r.pos + 1 <= r.size, "bif: truncated varint"
  let b0 = cast[ptr byte](r.base + uint(r.pos))[]
  let n = varintLen(b0)
  assert r.pos + n <= r.size, "bif: truncated varint"
  var buf = default(array[maxVarIntLen, byte])
  var i = 0
  while i < n:
    buf[i] = cast[ptr byte](r.base + uint(r.pos + i))[]
    inc i
  r.pos += n
  result = 0'u64
  discard readVu64(buf, result)

proc rStr(r: var BifReader): string =
  let n = int rVarint(r)
  assert r.pos + n <= r.size, "bif: truncated string"
  result = newString(n)
  if n > 0:
    copyMem(cast[pointer](beginStore(result, n)), cast[pointer](r.base + uint(r.pos)), n)
    endStore(result)
    r.pos += n

proc loadMappedProcessLifetime*(filename: string): BifModule =
  ## Memory-map a BIF and borrow its token block without ever releasing the
  ## mapping. Intended only for short-lived compiler processes. It retains the
  ## historical assert/quit behavior for malformed input; use `load` elsewhere.
  let blob = vfsOpenMmap(filename)          # left mapped for the buffer's lifetime
  var r = BifReader(base: cast[uint](blob.data), pos: 0, size: blob.size)
  block:                                    # magic
    let want = magic()
    assert r.size >= MagicLen, "bif: file too small"
    for i in 0 ..< MagicLen:
      if cast[ptr char](r.base + uint(i))[] != want[i]:
        quit "bif: bad magic / incompatible format or word size"
  r.pos = MagicLen
  discard rU64(r)                  # indexOffset — a full load reaches it linearly
  let tokenCount = int rVarint(r)
  let nTags      = int rVarint(r)
  let nStrings   = int rVarint(r)
  let nSyms      = int rVarint(r)
  let nFiles     = int rVarint(r)
  # Skip the alignment pad so the borrowed token block is NifToken-aligned. The
  # mapping's base is page-aligned, so aligning `r.pos` aligns the absolute address.
  r.pos += tokenPad(r.pos)
  # token block follows the varint header and is borrowed straight from the mapping.
  result = BifModule()
  let tokenBytes = tokenCount * sizeof(NifToken)
  assert r.pos + tokenBytes <= r.size, "bif: truncated token block"
  result.buf = adoptForeignTokens(cast[pointer](r.base + uint(r.pos)), tokenCount)
  r.pos += tokenBytes
  # pools: re-intern in stored (id) order so ids 1,2,… match the token refs.
  for _ in 1 .. nTags:    discard result.buf.tags.tags.getOrIncl(rStr(r))
  for _ in 1 .. nStrings: discard result.buf.pool.strings.getOrIncl(rStr(r))
  for _ in 1 .. nSyms:    discard result.buf.pool.syms.getOrIncl(rStr(r))
  for _ in 1 .. nFiles:   discard result.buf.pool.filenames.getOrIncl(rStr(r))
  # symbol index (we are now positioned exactly at indexOffset).
  let nIndex = int rVarint(r)
  result.index = newSeq[IndexEntry](nIndex)
  for i in 0 ..< nIndex:
    let sym = SymId rVarint(r)
    let pos = int32(rVarint(r))
    let v = int rVarint(r)
    result.index[i] = IndexEntry(sym: sym, pos: pos, vis: IndexVis(v))

# ── self-test ───────────────────────────────────────────────────────────────

when isMainModule:
  when defined(nimony):
    # Nimony's `system` has `assert` but not `doAssert`; the self-test wants an
    # always-on check, so provide the two arities it uses.
    template doAssert(cond: bool) =
      if not cond: quit "bif self-test: assertion failed"
    template doAssert(cond: bool; msg: string) =
      if not cond: quit "bif self-test: " & msg

  proc sameTokens(a, b: TokenBuf): bool =
    if a.len != b.len: return false
    for i in 0 ..< a.len:
      if not (a[i] == b[i]): return false
    true

  block round_trip:
    # Build a buffer exercising every pool + inline/overflow paths, then
    # store → load and require token-identical + pool-identical results.
    var src = createTokenBuf(16)
    let tFoo = src.tags.registerTag("foo")
    let tBar = src.tags.registerTag("bar")
    let f = src.pool.filenames.getOrIncl("some/where.nim")
    src.buildTree tFoo:
      src.appendLineInfo f, 10'i32, 2'i32
      src.buildTree tBar:
        src.addStrLit "hi"                         # inline (<=3)
        src.addStrLit "a longer interned string"   # pool
        src.addSymUse "some.long.symbol.name.0"    # sym pool
        src.addSymDef "another.symbol.def.1"
        src.addIntLit 42
        src.addIntLit 1'i64 shl 40                 # suffix-extended
        src.addUIntLit 0'u64
        src.addFloatLit 3.14
        src.addIdent "ident_name"

    let tmp = "/tmp/bif_selftest.bif"
    store(src, tmp)
    var m = load(tmp)
    doAssert sameTokens(src, m.buf), "token streams differ after round-trip"
    # pools must match value-for-value (so ids line up)
    doAssert m.buf.tags.tags.len == src.tags.tags.len
    doAssert m.buf.pool.strings.len == src.pool.strings.len
    doAssert m.buf.pool.syms.len == src.pool.syms.len
    doAssert m.buf.pool.filenames.len == src.pool.filenames.len
    # spot-check a decoded value via a cursor
    var c = m.buf.beginRead()
    doAssert c.kind == TagLit
    doAssert m.buf.tags.tagName(c.cursorTagId) == "foo"

    # The explicit process-lifetime mmap reader must agree with the checked,
    # owned default. It remains covered for short-lived compiler workers.
    let mapped = loadMappedProcessLifetime(tmp)
    doAssert sameTokens(src, mapped.buf), "mmap load disagrees with owned load"

    # The caller-owned File entry point follows the same checked path.
    var ff = open(tmp, fmRead)
    let fm = loadFromFile(ff)
    close(ff)
    doAssert sameTokens(src, fm.buf), "loadFromFile disagrees with owned load"
    doAssert fm.buf.pool.syms.len == src.pool.syms.len

    # containsSym probes only the syms table (skipping header, pad, tokens, tags,
    # strings); it must find a pooled name and reject an absent one.
    doAssert containsSym(tmp, "some.long.symbol.name.0")
    doAssert containsSym(tmp, "another.symbol.def.1")
    doAssert not containsSym(tmp, "no.such.symbol.here.9")

  block embedded_index:
    # A module-shaped buffer: a global exported def, a global hidden def, and a
    # purely-local def (< 2 dots) which must NOT be indexed.
    var src = createTokenBuf(16)
    let tStmts = src.tags.registerTag("stmts")
    let tSdef = src.tags.registerTag("sdef")
    src.buildTree tStmts:
      src.buildTree tSdef:                 # exported global: `x` marker
        src.addSymDef "foo.3.mymod"
        src.addIdent "x"
      src.buildTree tSdef:                 # hidden global: `.` marker
        src.addSymDef "bar.4.mymod"
        src.addDotToken()
      src.buildTree tSdef:                 # local (1 dot) -> not indexed
        src.addSymDef "loc.0"
        src.addIdent "x"

    let tmp = "/tmp/bif_index_selftest.bif"
    store(src, tmp, dottedSuffix = ".mymod")
    var m = load(tmp)
    doAssert m.index.len == 2, "expected 2 global syms, got " & $m.index.len
    # entry 0: foo, exported; its pos points at the enclosing (sdef tag.
    let e0 = m.index[0]
    doAssert m.buf.pool.syms[e0.sym] == "foo.3.mymod"
    doAssert e0.vis == ivExported
    var c = cursorAt(m.buf, int e0.pos)
    doAssert c.kind == TagLit and m.buf.tags.tagName(c.cursorTagId) == "sdef"
    # entry 1: bar, hidden.
    doAssert m.buf.pool.syms[m.index[1].sym] == "bar.4.mymod"
    doAssert m.index[1].vis == ivHidden

    let foo = m.findDeclaration("foo.3.mymod")
    doAssert not foo.cursorIsNil
    doAssert foo.kind == TagLit and m.buf.tags.tagName(foo.cursorTagId) == "sdef"
    doAssert m.findDeclaration("missing.0.mymod").cursorIsNil
    var declarationCount = 0
    for name, visibility, declaration in m.declarations:
      doAssert name in ["foo.3.mymod", "bar.4.mymod"]
      doAssert visibility in {ivExported, ivHidden}
      doAssert declaration.kind == TagLit
      inc declarationCount
    doAssert declarationCount == 2

    # jump-only load: following indexOffset must yield exactly the same entries
    # the full load produced, without touching the token block or pools.
    let idx = loadIndex(tmp)
    doAssert idx.len == m.index.len
    for i in 0 ..< idx.len:
      doAssert idx[i].sym == m.index[i].sym
      doAssert idx[i].pos == m.index[i].pos
      doAssert idx[i].vis == m.index[i].vis

  echo "bif self-tests passed"
