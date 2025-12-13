import std/[options, strformat, strutils, tables, sequtils]

import ../elfparser
import ../utils

# DWARF Call Frame Information (CFI) parser and interpreter.
# Supports common .eh_frame and .debug_frame layouts for 64-bit little-endian ELF.

type DwarfCfiError* = object of CatchableError

type
  DwarfCfiKind* = enum
    cfiEhFrame
    cfiDebugFrame

  DwarfCie* = object
    kind*: DwarfCfiKind
    offset*: uint64 # section-relative record offset
    version*: uint8
    augmentation*: string
    addressSize*: uint8
    segmentSize*: uint8
    codeAlign*: uint64
    dataAlign*: int64
    returnReg*: uint64
    ptrEncoding*: uint8 # DW_EH_PE_* for .eh_frame FDE addresses
    initialInstructions*: seq[byte]

  DwarfFde* = object
    offset*: uint64 # section-relative record offset
    cieOffset*: uint64
    initialLocation*: uint64
    addressRange*: uint64
    instructions*: seq[byte]

  DwarfCfiRegRuleKind* = enum
    drrUndefined
    drrSameValue
    drrOffset
    drrRegister

  DwarfCfiRegRule* = object
    kind*: DwarfCfiRegRuleKind
    offset*: int64 # for drrOffset
    reg*: uint64 # for drrRegister

  DwarfCfiRow* = object
    address*: uint64
    cfaReg*: uint64
    cfaOffset*: int64
    raOffset*: Option[int64]
    fpOffset*: Option[int64]

const
  DW_EH_PE_absptr = 0x00'u8
  DW_EH_PE_uleb128 = 0x01'u8
  DW_EH_PE_udata2 = 0x02'u8
  DW_EH_PE_udata4 = 0x03'u8
  DW_EH_PE_udata8 = 0x04'u8
  DW_EH_PE_sleb128 = 0x09'u8
  DW_EH_PE_sdata2 = 0x0A'u8
  DW_EH_PE_sdata4 = 0x0B'u8
  DW_EH_PE_sdata8 = 0x0C'u8
  DW_EH_PE_pcrel = 0x10'u8
  DW_EH_PE_textrel = 0x20'u8
  DW_EH_PE_datarel = 0x30'u8
  DW_EH_PE_funcrel = 0x40'u8
  DW_EH_PE_aligned = 0x50'u8
  DW_EH_PE_indirect = 0x80'u8
  DW_EH_PE_omit = 0xFF'u8

const
  DW_CFA_nop = 0x00'u8
  DW_CFA_set_loc = 0x01'u8
  DW_CFA_advance_loc1 = 0x02'u8
  DW_CFA_advance_loc2 = 0x03'u8
  DW_CFA_advance_loc4 = 0x04'u8
  DW_CFA_offset_extended = 0x05'u8
  DW_CFA_restore_extended = 0x06'u8
  DW_CFA_undefined = 0x07'u8
  DW_CFA_same_value = 0x08'u8
  DW_CFA_register = 0x09'u8
  DW_CFA_remember_state = 0x0A'u8
  DW_CFA_restore_state = 0x0B'u8
  DW_CFA_def_cfa = 0x0C'u8
  DW_CFA_def_cfa_register = 0x0D'u8
  DW_CFA_def_cfa_offset = 0x0E'u8
  DW_CFA_def_cfa_expression = 0x0F'u8
  DW_CFA_expression = 0x10'u8
  DW_CFA_offset_extended_sf = 0x11'u8
  DW_CFA_def_cfa_sf = 0x12'u8
  DW_CFA_def_cfa_offset_sf = 0x13'u8
  DW_CFA_val_offset = 0x14'u8
  DW_CFA_val_offset_sf = 0x15'u8
  DW_CFA_val_expression = 0x16'u8
  DW_CFA_lo_user = 0x1C'u8
  DW_CFA_GNU_args_size = 0x2E'u8
  DW_CFA_GNU_negative_offset_extended = 0x2F'u8

proc readU64LE(data: openArray[byte], idx: var int): uint64 =
  if idx + 8 > data.len:
    raise newException(DwarfCfiError, "Read past end of buffer")
  result = getU64LE(data, idx)
  idx += 8

proc readU32LE(data: openArray[byte], idx: var int): uint32 =
  if idx + 4 > data.len:
    raise newException(DwarfCfiError, "Read past end of buffer")
  result = getU32LE(data, idx)
  idx += 4

proc readU16LE(data: openArray[byte], idx: var int): uint16 =
  if idx + 2 > data.len:
    raise newException(DwarfCfiError, "Read past end of buffer")
  result = getU16LE(data, idx)
  idx += 2

proc readUIntLE(data: openArray[byte], idx: var int, size: uint8): uint64 =
  case size
  of 2'u8:
    result = uint64(readU16LE(data, idx))
  of 4'u8:
    result = uint64(readU32LE(data, idx))
  of 8'u8:
    result = readU64LE(data, idx)
  else:
    raise newException(DwarfCfiError, fmt"Unsupported integer size {size}")

proc readCString(data: openArray[byte], idx: var int, limit: int): string =
  let start = idx
  while idx < limit and data[idx] != 0'u8:
    inc idx
  if idx >= limit:
    raise newException(DwarfCfiError, "Unterminated C string")
  let n = idx - start
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(data[start + i])
  inc idx

proc readLengthField(data: openArray[byte], idx: var int): tuple[length: uint64, is64: bool] =
  let l32 = readU32LE(data, idx)
  if l32 == 0xFFFF_FFFF'u32:
    (readU64LE(data, idx), true)
  else:
    (uint64(l32), false)

proc skipEncodedPointer(
    data: openArray[byte], idx: var int, encoding: uint8, addressSize: uint8
) =
  if encoding == DW_EH_PE_omit:
    return
  let format = encoding and 0x0F
  case format
  of DW_EH_PE_absptr:
    discard readUIntLE(data, idx, addressSize)
  of DW_EH_PE_udata2:
    discard readUIntLE(data, idx, 2)
  of DW_EH_PE_udata4:
    discard readUIntLE(data, idx, 4)
  of DW_EH_PE_udata8:
    discard readUIntLE(data, idx, 8)
  of DW_EH_PE_uleb128:
    discard readULeb128(data, idx)
  of DW_EH_PE_sdata2:
    let u = uint16(readUIntLE(data, idx, 2))
    discard cast[int16](u)
  of DW_EH_PE_sdata4:
    let u = uint32(readUIntLE(data, idx, 4))
    discard cast[int32](u)
  of DW_EH_PE_sdata8:
    let u = uint64(readUIntLE(data, idx, 8))
    discard cast[int64](u)
  of DW_EH_PE_sleb128:
    discard readSLeb128(data, idx)
  else:
    raise newException(
      DwarfCfiError, fmt"Unsupported pointer format 0x{toHex(int(format), 2)}"
    )

proc readEncodedPointer(
    data: openArray[byte],
    idx: var int,
    encoding: uint8,
    addressSize: uint8,
    fieldVaddr: uint64,
    isRange: bool,
): uint64 =
  if encoding == DW_EH_PE_omit:
    return 0
  let format = encoding and 0x0F
  let application = encoding and 0x70
  let indirect = (encoding and DW_EH_PE_indirect) != 0
  if indirect:
    raise newException(DwarfCfiError, "Indirect encoded pointers not supported")

  var rawUnsigned: uint64 = 0
  var rawSigned: int64 = 0
  case format
  of DW_EH_PE_absptr:
    rawUnsigned = readUIntLE(data, idx, addressSize)
    rawSigned = int64(rawUnsigned)
  of DW_EH_PE_udata2:
    rawUnsigned = readUIntLE(data, idx, 2)
    rawSigned = int64(rawUnsigned)
  of DW_EH_PE_udata4:
    rawUnsigned = readUIntLE(data, idx, 4)
    rawSigned = int64(rawUnsigned)
  of DW_EH_PE_udata8:
    rawUnsigned = readUIntLE(data, idx, 8)
    rawSigned = int64(rawUnsigned)
  of DW_EH_PE_uleb128:
    rawUnsigned = readULeb128(data, idx)
    rawSigned = int64(rawUnsigned)
  of DW_EH_PE_sdata2:
    let u = uint16(readUIntLE(data, idx, 2))
    rawUnsigned = uint64(u)
    rawSigned = int64(cast[int16](u))
  of DW_EH_PE_sdata4:
    let u = uint32(readUIntLE(data, idx, 4))
    rawUnsigned = uint64(u)
    rawSigned = int64(cast[int32](u))
  of DW_EH_PE_sdata8:
    let u = uint64(readUIntLE(data, idx, 8))
    rawUnsigned = u
    rawSigned = cast[int64](u)
  of DW_EH_PE_sleb128:
    rawSigned = readSLeb128(data, idx)
    rawUnsigned = cast[uint64](rawSigned)
  else:
    raise newException(
      DwarfCfiError, fmt"Unsupported pointer format 0x{toHex(int(format), 2)}"
    )

  if isRange or application == 0'u8:
    return rawUnsigned
  if application == DW_EH_PE_pcrel:
    return uint64(int64(fieldVaddr) + rawSigned)
  raise newException(
    DwarfCfiError, fmt"Unsupported pointer application 0x{toHex(int(application), 2)}"
  )

proc parseCie(
    data: openArray[byte],
    kind: DwarfCfiKind,
    recordOffset: uint64,
    startIdx: int,
    entryEnd: int,
): DwarfCie =
  var idx = startIdx
  let version = data[idx]
  inc idx
  let augmentation = readCString(data, idx, entryEnd)

  var addressSize: uint8 = 8
  var segmentSize: uint8 = 0
  if kind == cfiDebugFrame and version >= 4'u8:
    addressSize = data[idx]
    inc idx
    segmentSize = data[idx]
    inc idx

  let codeAlign = readULeb128(data, idx)
  let dataAlign = readSLeb128(data, idx)
  let returnReg = readULeb128(data, idx)

  var ptrEncoding = DW_EH_PE_absptr
  if augmentation.len > 0 and augmentation[0] == 'z':
    let augLen = int(readULeb128(data, idx))
    let augEnd = idx + augLen
    if augEnd > entryEnd:
      raise newException(DwarfCfiError, "Augmentation length past record end")
    for j in 1 ..< augmentation.len:
      let ch = augmentation[j]
      case ch
      of 'R':
        if idx >= augEnd:
          raise newException(DwarfCfiError, "Augmentation R past end")
        ptrEncoding = data[idx]
        inc idx
      of 'P':
        if idx >= augEnd:
          raise newException(DwarfCfiError, "Augmentation P past end")
        let enc = data[idx]
        inc idx
        skipEncodedPointer(data, idx, enc, addressSize)
      of 'L':
        if idx >= augEnd:
          raise newException(DwarfCfiError, "Augmentation L past end")
        inc idx # LSDA encoding byte
      of 'S':
        discard
      else:
        discard
    idx = augEnd

  result = DwarfCie(
    kind: kind,
    offset: recordOffset,
    version: version,
    augmentation: augmentation,
    addressSize: addressSize,
    segmentSize: segmentSize,
    codeAlign: codeAlign,
    dataAlign: dataAlign,
    returnReg: returnReg,
    ptrEncoding: ptrEncoding,
    initialInstructions: @[],
  )
  if idx < entryEnd:
    result.initialInstructions = data[idx ..< entryEnd]

proc parseFde(
    data: openArray[byte],
    kind: DwarfCfiKind,
    recordOffset: uint64,
    startIdx: int,
    entryEnd: int,
    sectionAddr: uint64,
    cie: DwarfCie,
    cieOffset: uint64,
): DwarfFde =
  var idx = startIdx
  var initialLocation: uint64 = 0
  var addressRange: uint64 = 0

  if kind == cfiEhFrame:
    let fieldVaddr = sectionAddr + uint64(idx)
    initialLocation =
      readEncodedPointer(data, idx, cie.ptrEncoding, cie.addressSize, fieldVaddr, false)
    let rangeEnc = cie.ptrEncoding and 0x0F
    addressRange =
      readEncodedPointer(data, idx, rangeEnc, cie.addressSize, 0'u64, true)
  else:
    initialLocation = readUIntLE(data, idx, cie.addressSize)
    addressRange = readUIntLE(data, idx, cie.addressSize)

  # Skip FDE augmentation data if CIE uses 'z'
  if cie.augmentation.len > 0 and cie.augmentation[0] == 'z':
    let augLen = int(readULeb128(data, idx))
    idx += augLen
    if idx > entryEnd:
      raise newException(DwarfCfiError, "FDE augmentation length past record end")

  result = DwarfFde(
    offset: recordOffset,
    cieOffset: cieOffset,
    initialLocation: initialLocation,
    addressRange: addressRange,
    instructions: @[],
  )
  if idx < entryEnd:
    result.instructions = data[idx ..< entryEnd]

proc parseDwarfCfi*(
    elf: ElfFile, kind: DwarfCfiKind = cfiEhFrame
): seq[tuple[fde: DwarfFde, cie: DwarfCie]] =
  let sectionName = if kind == cfiEhFrame: ".eh_frame" else: ".debug_frame"
  let secIdx = elf.findSection(sectionName)
  if secIdx < 0:
    raise newException(DwarfCfiError, fmt"No {sectionName} section found")
  let sec = elf.sections[secIdx]
  let data = sec.data
  let sectionAddr = sec.address

  var ciesByOffset: Table[uint64, DwarfCie]
  var resultPairs: seq[tuple[fde: DwarfFde, cie: DwarfCie]] = @[]

  var idx = 0
  while idx < data.len:
    let recordStart = idx
    let (length, is64) = readLengthField(data, idx)
    if length == 0'u64:
      break
    let entryEnd = idx + int(length)
    if entryEnd > data.len:
      raise newException(DwarfCfiError, "CFI record past end of section")

    let idFieldStart = idx
    var idVal: uint64
    if kind == cfiDebugFrame and is64:
      idVal = readU64LE(data, idx)
    else:
      idVal = uint64(readU32LE(data, idx))

    let isCie =
      (kind == cfiEhFrame and idVal == 0'u64) or
      (kind == cfiDebugFrame and ((not is64 and idVal == 0xFFFF_FFFF'u64) or
        (is64 and idVal == 0xFFFF_FFFF_FFFF_FFFF'u64)))

    if isCie:
      let cie = parseCie(
        data = data,
        kind = kind,
        recordOffset = uint64(recordStart),
        startIdx = idx,
        entryEnd = entryEnd,
      )
      ciesByOffset[cie.offset] = cie
    else:
      var cieOffset: uint64
      if kind == cfiEhFrame:
        let ciePointer = idVal
        cieOffset = uint64(idFieldStart) - ciePointer
      else:
        cieOffset = idVal
      if not ciesByOffset.hasKey(cieOffset):
        raise newException(
          DwarfCfiError, fmt"Missing CIE at offset 0x{cieOffset.toHex}"
        )
      let cie = ciesByOffset[cieOffset]
      let fde = parseFde(
        data = data,
        kind = kind,
        recordOffset = uint64(recordStart),
        startIdx = idx,
        entryEnd = entryEnd,
        sectionAddr = sectionAddr,
        cie = cie,
        cieOffset = cieOffset,
      )
      resultPairs.add((fde: fde, cie: cie))

    idx = entryEnd

  result = resultPairs

type
  CfiState = object
    address: uint64
    cfaReg: uint64
    cfaOffset: int64
    raRule: DwarfCfiRegRule
    fpRule: DwarfCfiRegRule

proc rowFromState(state: CfiState): DwarfCfiRow =
  result.address = state.address
  result.cfaReg = state.cfaReg
  result.cfaOffset = state.cfaOffset
  if state.raRule.kind == drrOffset:
    result.raOffset = some(state.raRule.offset)
  else:
    result.raOffset = none(int64)
  if state.fpRule.kind == drrOffset:
    result.fpOffset = some(state.fpRule.offset)
  else:
    result.fpOffset = none(int64)

proc pushRow(rows: var seq[DwarfCfiRow], state: CfiState) =
  let row = rowFromState(state)
  if rows.len > 0 and rows[^1].address == row.address:
    rows[^1] = row
  else:
    rows.add(row)

proc applyRule(
    state: var CfiState,
    reg: uint64,
    rule: DwarfCfiRegRule,
    returnReg: uint64,
    fpReg: uint64,
) =
  if reg == returnReg:
    state.raRule = rule
  if reg == fpReg:
    state.fpRule = rule

proc interpretProgram(
    instructions: openArray[byte],
    cie: DwarfCie,
    state: var CfiState,
    initialRa: DwarfCfiRegRule,
    initialFp: DwarfCfiRegRule,
    fpReg: uint64,
    emitRows: bool,
    rows: var seq[DwarfCfiRow],
) =
  var idx = 0
  var stack: seq[CfiState] = @[]
  while idx < instructions.len:
    let op = instructions[idx]
    inc idx
    let primary = op and 0xC0'u8
    if primary != 0'u8:
      let operand = uint64(op and 0x3F'u8)
      case primary
      of 0x40'u8: # advance_loc
        state.address += operand * cie.codeAlign
        if emitRows:
          pushRow(rows, state)
      of 0x80'u8: # offset
        let offFact = readULeb128(instructions, idx)
        let off = int64(offFact) * cie.dataAlign
        applyRule(
          state,
          operand,
          DwarfCfiRegRule(kind: drrOffset, offset: off, reg: 0),
          cie.returnReg,
          fpReg,
        )
        if emitRows:
          pushRow(rows, state)
      of 0xC0'u8: # restore
        if operand == cie.returnReg:
          state.raRule = initialRa
        if operand == fpReg:
          state.fpRule = initialFp
        if emitRows:
          pushRow(rows, state)
      else:
        discard
      continue

    case op
    of DW_CFA_nop:
      discard
    of DW_CFA_set_loc:
      state.address = readUIntLE(instructions, idx, cie.addressSize)
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_advance_loc1:
      let delta = uint64(instructions[idx])
      inc idx
      state.address += delta * cie.codeAlign
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_advance_loc2:
      let delta = uint64(readU16LE(instructions, idx))
      state.address += delta * cie.codeAlign
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_advance_loc4:
      let delta = uint64(readU32LE(instructions, idx))
      state.address += delta * cie.codeAlign
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_def_cfa:
      state.cfaReg = readULeb128(instructions, idx)
      state.cfaOffset = int64(readULeb128(instructions, idx))
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_def_cfa_register:
      state.cfaReg = readULeb128(instructions, idx)
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_def_cfa_offset:
      state.cfaOffset = int64(readULeb128(instructions, idx))
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_def_cfa_sf:
      state.cfaReg = readULeb128(instructions, idx)
      let offFact = readSLeb128(instructions, idx)
      state.cfaOffset = offFact * cie.dataAlign
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_def_cfa_offset_sf:
      let offFact = readSLeb128(instructions, idx)
      state.cfaOffset = offFact * cie.dataAlign
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_offset_extended:
      let reg = readULeb128(instructions, idx)
      let offFact = readULeb128(instructions, idx)
      let off = int64(offFact) * cie.dataAlign
      applyRule(
        state,
        reg,
        DwarfCfiRegRule(kind: drrOffset, offset: off, reg: 0),
        cie.returnReg,
        fpReg,
      )
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_offset_extended_sf:
      let reg = readULeb128(instructions, idx)
      let offFact = readSLeb128(instructions, idx)
      let off = offFact * cie.dataAlign
      applyRule(
        state,
        reg,
        DwarfCfiRegRule(kind: drrOffset, offset: off, reg: 0),
        cie.returnReg,
        fpReg,
      )
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_restore_extended:
      let reg = readULeb128(instructions, idx)
      if reg == cie.returnReg:
        state.raRule = initialRa
      if reg == fpReg:
        state.fpRule = initialFp
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_same_value:
      let reg = readULeb128(instructions, idx)
      applyRule(
        state,
        reg,
        DwarfCfiRegRule(kind: drrSameValue, offset: 0, reg: 0),
        cie.returnReg,
        fpReg,
      )
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_undefined:
      let reg = readULeb128(instructions, idx)
      applyRule(
        state,
        reg,
        DwarfCfiRegRule(kind: drrUndefined, offset: 0, reg: 0),
        cie.returnReg,
        fpReg,
      )
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_register:
      let reg = readULeb128(instructions, idx)
      let reg2 = readULeb128(instructions, idx)
      applyRule(
        state,
        reg,
        DwarfCfiRegRule(kind: drrRegister, offset: 0, reg: reg2),
        cie.returnReg,
        fpReg,
      )
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_remember_state:
      stack.add(state)
    of DW_CFA_restore_state:
      if stack.len == 0:
        raise newException(DwarfCfiError, "restore_state with empty stack")
      state = stack[^1]
      stack.setLen(stack.len - 1)
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_expression, DW_CFA_def_cfa_expression, DW_CFA_val_expression:
      let blen = int(readULeb128(instructions, idx))
      idx += blen
      if idx > instructions.len:
        raise newException(DwarfCfiError, "expression block past end")
    of DW_CFA_val_offset:
      let reg = readULeb128(instructions, idx)
      let offFact = readULeb128(instructions, idx)
      let off = int64(offFact) * cie.dataAlign
      applyRule(
        state,
        reg,
        DwarfCfiRegRule(kind: drrOffset, offset: off, reg: 0),
        cie.returnReg,
        fpReg,
      )
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_val_offset_sf:
      let reg = readULeb128(instructions, idx)
      let offFact = readSLeb128(instructions, idx)
      let off = offFact * cie.dataAlign
      applyRule(
        state,
        reg,
        DwarfCfiRegRule(kind: drrOffset, offset: off, reg: 0),
        cie.returnReg,
        fpReg,
      )
      if emitRows:
        pushRow(rows, state)
    of DW_CFA_GNU_args_size:
      discard readULeb128(instructions, idx)
    of DW_CFA_GNU_negative_offset_extended:
      let reg = readULeb128(instructions, idx)
      let offFact = readULeb128(instructions, idx)
      let off = -int64(offFact) * cie.dataAlign
      applyRule(
        state,
        reg,
        DwarfCfiRegRule(kind: drrOffset, offset: off, reg: 0),
        cie.returnReg,
        fpReg,
      )
      if emitRows:
        pushRow(rows, state)
    else:
      if op >= DW_CFA_lo_user:
        raise newException(
          DwarfCfiError, fmt"Unsupported CFI opcode 0x{toHex(int(op), 2)}"
        )
      else:
        raise newException(
          DwarfCfiError, fmt"Unknown CFI opcode 0x{toHex(int(op), 2)}"
        )

proc computeCfiRows*(
    fde: DwarfFde, cie: DwarfCie, fpReg: uint64
): seq[DwarfCfiRow] =
  var baseState = CfiState(
    address: fde.initialLocation,
    cfaReg: 0'u64,
    cfaOffset: 0'i64,
    raRule: DwarfCfiRegRule(kind: drrUndefined, offset: 0, reg: 0),
    fpRule: DwarfCfiRegRule(kind: drrUndefined, offset: 0, reg: 0),
  )
  var initRows: seq[DwarfCfiRow] = @[]
  var initState = baseState
  interpretProgram(
    instructions = cie.initialInstructions,
    cie = cie,
    state = initState,
    initialRa = initState.raRule,
    initialFp = initState.fpRule,
    fpReg = fpReg,
    emitRows = false,
    rows = initRows,
  )
  let initialRa = initState.raRule
  let initialFp = initState.fpRule

  var rows: seq[DwarfCfiRow] = @[]
  var state = initState
  state.address = fde.initialLocation
  pushRow(rows, state)
  interpretProgram(
    instructions = fde.instructions,
    cie = cie,
    state = state,
    initialRa = initialRa,
    initialFp = initialFp,
    fpReg = fpReg,
    emitRows = true,
    rows = rows,
  )

  let endAddr = fde.initialLocation + fde.addressRange
  result = rows.filterIt(it.address < endAddr)
