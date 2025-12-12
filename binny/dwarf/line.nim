## DWARF Line Number Program Implementation
##
## This module implements DWARF line number program parsing and execution
## based on the DWARF specification section 6.2.
##
## Ported from gimli-rs (https://github.com/gimli-rs/gimli) under MIT license.
## MIT Copyright (c) 2015 The Rust Project Developers

import std/options
import ./dwarftypes
import ../utils

proc readNullTerminated(data: openArray[byte]; offset: var int; limit: int): Option[string] =
  ## Read a null-terminated string bounded by limit.
  if offset >= limit:
    return none(string)

  var endIdx = offset
  while endIdx < limit and data[endIdx] != 0'u8:
    inc endIdx

  if endIdx >= limit:
    return none(string)

  var s = newString(endIdx - offset)
  for i in 0 ..< (endIdx - offset):
    s[i] = char(data[offset + i])

  offset = endIdx + 1
  some(s)

proc readULeb128Limited(data: openArray[byte]; offset: var int; limit: int): Option[uint64] =
  ## Read a ULEB128 value ensuring we do not read past limit.
  var value: uint64 = 0
  var shift = 0
  var idx = offset

  while idx < limit:
    let byteVal = data[idx]
    inc idx
    value = value or (uint64(byteVal and 0x7f) shl shift)
    if (byteVal and 0x80) == 0:
      offset = idx
      return some(value)
    shift += 7

  none(uint64)

proc readAddressLimited(data: openArray[byte];
                        offset: var int;
                        limit: int;
                        addressSize: int): Option[uint64] =
  ## Read a target address honoring the program's address size.
  if addressSize <= 0 or addressSize > 8:
    return none(uint64)
  if offset + addressSize > limit:
    return none(uint64)

  var value: uint64 = 0
  for i in 0..<addressSize:
    value = value or (uint64(data[offset + i]) shl (i * 8))
  offset += addressSize
  some(value)

# Column type for line number information
type
  ColumnType* = object
    case kind*: bool
    of false:  # LeftEdge - statement begins at start of line
      discard
    of true:   # Column number (1-based)
      column*: uint64

  LineFileEntry* = object
    fileName*: string
    directoryIndex*: uint64
    timestamp*: uint64
    size*: uint64

# Line instruction variants
type
  LineInstructionKind* = enum
    liSpecial              # Special opcode (combined address + line advance)
    liCopy                 # Copy current registers to matrix
    liAdvancePc            # Advance program counter
    liAdvanceLine          # Advance line number
    liSetFile              # Set file register
    liSetColumn            # Set column register
    liNegateStatement      # Negate is_stmt register
    liSetBasicBlock        # Set basic_block register
    liConstAddPc           # Advance PC by fixed amount
    liFixedAddPc           # Fixed advance PC
    liSetPrologueEnd       # Mark prologue end
    liSetEpilogueBegin     # Mark epilogue begin
    liSetIsa               # Set instruction set architecture
    liEndSequence          # End sequence (also adds row)
    liSetAddress           # Set address register
    liDefineFile           # Define a new file (DWARF 4 and earlier)
    liSetDiscriminator     # Set discriminator register
    liUnknownStandard0     # Unknown standard opcode with no operands
    liUnknownStandard1     # Unknown standard opcode with one operand
    liUnknownStandardN     # Unknown standard opcode with many operands
    liUnknownExtended      # Unknown extended opcode

  LineInstruction* = object
    stdOpcode*: uint8
    case kind*: LineInstructionKind
    of liSpecial:
      opcode*: uint8
    of liCopy:
      discard
    of liAdvancePc:
      pcAdvance*: uint64
    of liAdvanceLine:
      lineIncrement*: int64
    of liSetFile:
      fileIndex*: uint64
    of liSetColumn:
      columnNum*: uint64
    of liNegateStatement, liSetBasicBlock, liSetPrologueEnd,
       liSetEpilogueBegin, liConstAddPc:
      discard
    of liFixedAddPc:
      fixedAdvance*: uint16
    of liSetIsa:
      isa*: uint64
    of liEndSequence:
      discard
    of liSetAddress:
      address*: uint64
    of liDefineFile:
      fileEntry*: LineFileEntry
    of liSetDiscriminator:
      discriminator*: uint64
    of liUnknownStandard0:
      discard
    of liUnknownStandard1:
      stdArg*: uint64
    of liUnknownStandardN:
      stdArgs*: seq[uint64]
    of liUnknownExtended:
      extOpcode*: uint8
      extData*: seq[byte]

# Line number program state machine row
type
  LineRow* = object
    tombstone*: bool          # Address is a tombstone marker
    address*: uint64          # Current address
    opIndex*: uint64          # Operation index (for VLIW)
    file*: uint64             # File index (1-based)
    line*: uint64             # Line number (1-based, 0=no line)
    column*: uint64           # Column number (0=left edge)
    isStmt*: bool             # Recommended breakpoint location
    basicBlock*: bool         # Beginning of basic block
    endSequence*: bool        # End of instruction sequence
    prologueEnd*: bool        # End of function prologue
    epilogueBegin*: bool      # Beginning of function epilogue
    isa*: uint64              # Instruction set architecture
    discriminator*: uint64    # Block discriminator

# Helper procs for LineRow
proc newLineRow*(header: DwarfLineHeader): LineRow =
  ## Create a new line row in the initial state
  result = LineRow(
    tombstone: false,
    address: 0,
    opIndex: 0,
    file: 1,
    line: 1,
    column: 0,
    isStmt: header.defaultIsStmt != 0,
    basicBlock: false,
    endSequence: false,
    prologueEnd: false,
    epilogueBegin: false,
    isa: 0,
    discriminator: 0
  )

proc getColumn*(row: LineRow): ColumnType =
  ## Get column information
  if row.column == 0:
    ColumnType(kind: false)
  else:
    ColumnType(kind: true, column: row.column)

proc getLine*(row: LineRow): Option[uint64] =
  ## Get line number (returns none if line is 0)
  if row.line == 0:
    none(uint64)
  else:
    some(row.line)

# Line advance helper
proc applyLineAdvance*(row: var LineRow; lineIncrement: int64) =
  ## Apply line number increment (step 1 of section 6.2.5.1)
  if lineIncrement < 0:
    let decrement = uint64(-lineIncrement)
    if decrement <= row.line:
      row.line -= decrement
    else:
      row.line = 0
  else:
    row.line += uint64(lineIncrement)

# Operation advance helper
proc applyOperationAdvance*(row: var LineRow;
                           operationAdvance: uint64;
                           header: DwarfLineHeader) =
  ## Apply operation advance (step 2 of section 6.2.5.1)
  ## Raises ValueError on overflow
  if row.tombstone:
    return

  let minInsnLen = uint64(header.minInstructionLength)
  let maxOpsPerInsn = uint64(header.maxOpsPerInsn)

  var addressAdvance: uint64

  if maxOpsPerInsn == 1:
    row.opIndex = 0
    addressAdvance = minInsnLen * operationAdvance
  else:
    let opIndexWithAdvance = row.opIndex + operationAdvance
    row.opIndex = opIndexWithAdvance mod maxOpsPerInsn
    addressAdvance = minInsnLen * (opIndexWithAdvance div maxOpsPerInsn)

  # Check for overflow
  if addressAdvance > (high(uint64) - row.address):
    raise newException(ValueError, "DWARF line address overflow")

  row.address += addressAdvance

proc adjustOpcode*(opcode: uint8; header: DwarfLineHeader): uint8 {.inline.} =
  ## Adjust opcode by subtracting opcode_base
  opcode - header.opcodeBase

proc execSpecialOpcode*(row: var LineRow;
                        opcode: uint8;
                        header: DwarfLineHeader) =
  ## Execute a special opcode (section 6.2.5.1)
  let adjustedOpcode = adjustOpcode(opcode, header)

  if header.lineRange == 0:
    raise newException(ValueError, "Invalid line range in DWARF header")

  let lineAdvance = adjustedOpcode mod header.lineRange
  let operationAdvance = adjustedOpcode div header.lineRange

  # Step 1: Apply line advance
  let lineBase = int64(header.lineBase)
  row.applyLineAdvance(lineBase + int64(lineAdvance))

  # Step 2: Apply operation advance
  row.applyOperationAdvance(uint64(operationAdvance), header)

proc reset*(row: var LineRow; header: DwarfLineHeader) =
  ## Reset row state after emitting
  if row.endSequence:
    # Reset to initial state
    row = newLineRow(header)
  else:
    # Reset per-row state (after Copy or Special)
    row.discriminator = 0
    row.basicBlock = false
    row.prologueEnd = false
    row.epilogueBegin = false

# Minimum tombstone address helper
proc minTombstone(addressSize: uint8): uint64 =
  ## Get minimum tombstone address for given address size
  ## DWARF uses -1 as tombstone, but linkers may use -2
  case addressSize
  of 1: 0xFE'u64
  of 2: 0xFFFE'u64
  of 4: 0xFFFFFFFE'u64
  of 8: 0xFFFFFFFFFFFFFFFE'u64
  else: high(uint64)

proc executeInstruction*(row: var LineRow;
                        instruction: LineInstruction;
                        header: DwarfLineHeader;
                        addressSize: uint8): bool =
  ## Execute a line instruction and return true if a row should be emitted
  ## Returns false on error or if no row should be emitted
  case instruction.kind
  of liSpecial:
    row.execSpecialOpcode(instruction.opcode, header)
    return true

  of liCopy:
    return true

  of liAdvancePc:
    row.applyOperationAdvance(instruction.pcAdvance, header)
    return false

  of liAdvanceLine:
    row.applyLineAdvance(instruction.lineIncrement)
    return false

  of liSetFile:
    row.file = instruction.fileIndex
    return false

  of liSetColumn:
    row.column = instruction.columnNum
    return false

  of liNegateStatement:
    row.isStmt = not row.isStmt
    return false

  of liSetBasicBlock:
    row.basicBlock = true
    return false

  of liConstAddPc:
    # Special opcode 255
    let adjusted = adjustOpcode(255, header)
    let operationAdvance = adjusted div header.lineRange
    row.applyOperationAdvance(uint64(operationAdvance), header)
    return false

  of liFixedAddPc:
    if not row.tombstone:
      let advance = uint64(instruction.fixedAdvance)
      if advance > (high(uint64) - row.address):
        raise newException(ValueError, "DWARF line fixed advance overflow")
      row.address += advance
      row.opIndex = 0
    return false

  of liSetPrologueEnd:
    row.prologueEnd = true
    return false

  of liSetEpilogueBegin:
    row.epilogueBegin = true
    return false

  of liSetIsa:
    row.isa = instruction.isa
    return false

  of liEndSequence:
    row.endSequence = true
    return true

  of liSetAddress:
    # Check for tombstone value
    # DWARF uses -1, but linkers may use 0 or other low values
    # Addresses must be monotonically increasing within a sequence
    row.tombstone = instruction.address < row.address or
                   instruction.address >= minTombstone(addressSize)
    if not row.tombstone:
      row.address = instruction.address
      row.opIndex = 0
    return false

  of liSetDiscriminator:
    row.discriminator = instruction.discriminator
    return false

  of liDefineFile, liUnknownStandard0, liUnknownStandard1,
     liUnknownStandardN, liUnknownExtended:
    # No-op for unknown instructions
    return false

# Instruction parsing
proc parseLineInstruction*(data: openArray[byte];
                          offset: var int;
                          header: DwarfLineHeader;
                          addressSize: uint8): Option[LineInstruction] =
  ## Parse a line number instruction from data
  ## Returns none on error or end of data
  if offset >= data.len:
    return none(LineInstruction)

  let opcode = data[offset]
  inc offset

  if opcode == 0:
    let extLen = readULeb128(data, offset)
    if extLen == 0:
      return none(LineInstruction)
    if extLen > uint64(high(int)):
      return none(LineInstruction)
    let extLenInt = int(extLen)
    if offset + extLenInt > data.len:
      return none(LineInstruction)

    let chunkEnd = offset + extLenInt
    let extOpcode = data[offset]
    inc offset

    let payloadStart = offset
    case extOpcode
    of DW_LNE_end_sequence:
      offset = chunkEnd
      return some(LineInstruction(kind: liEndSequence))

    of DW_LNE_set_address:
      var payloadOffset = payloadStart
      let addrOpt = readAddressLimited(data, payloadOffset, chunkEnd, int(addressSize))
      if addrOpt.isNone:
        return none(LineInstruction)
      offset = chunkEnd
      return some(LineInstruction(kind: liSetAddress, address: get(addrOpt)))

    of DW_LNE_define_file:
      if header.version > 4:
        let extData = if payloadStart < chunkEnd:
                        @data[payloadStart..<chunkEnd]
                      else:
                        @[]
        offset = chunkEnd
        return some(LineInstruction(kind: liUnknownExtended,
                                   extOpcode: extOpcode,
                                   extData: extData))

      var payloadOffset = payloadStart
      let nameOpt = readNullTerminated(data, payloadOffset, chunkEnd)
      if nameOpt.isNone:
        return none(LineInstruction)

      let dirOpt = readULeb128Limited(data, payloadOffset, chunkEnd)
      if dirOpt.isNone:
        return none(LineInstruction)

      let timeOpt = readULeb128Limited(data, payloadOffset, chunkEnd)
      if timeOpt.isNone:
        return none(LineInstruction)

      let sizeOpt = readULeb128Limited(data, payloadOffset, chunkEnd)
      if sizeOpt.isNone:
        return none(LineInstruction)

      let entry = LineFileEntry(
        fileName: get(nameOpt),
        directoryIndex: get(dirOpt),
        timestamp: get(timeOpt),
        size: get(sizeOpt)
      )
      offset = chunkEnd
      return some(LineInstruction(kind: liDefineFile, fileEntry: entry))

    of DW_LNE_set_discriminator:
      var payloadOffset = payloadStart
      let discOpt = readULeb128Limited(data, payloadOffset, chunkEnd)
      if discOpt.isNone:
        return none(LineInstruction)
      offset = chunkEnd
      return some(LineInstruction(kind: liSetDiscriminator,
                                 discriminator: get(discOpt)))

    else:
      let extData = if payloadStart < chunkEnd:
                      @data[payloadStart..<chunkEnd]
                    else:
                      @[]
      offset = chunkEnd
      return some(LineInstruction(kind: liUnknownExtended,
                                 extOpcode: extOpcode,
                                 extData: extData))

  elif opcode >= header.opcodeBase:
    # Special opcode
    return some(LineInstruction(kind: liSpecial, opcode: opcode))

  else:
    # Standard opcode
    case opcode
    of DW_LNS_copy:
      return some(LineInstruction(kind: liCopy))

    of DW_LNS_advance_pc:
      let advance = readULeb128(data, offset)
      return some(LineInstruction(kind: liAdvancePc, pcAdvance: advance))

    of DW_LNS_advance_line:
      let increment = readSLeb128(data, offset)
      return some(LineInstruction(kind: liAdvanceLine, lineIncrement: increment))

    of DW_LNS_set_file:
      let file = readULeb128(data, offset)
      return some(LineInstruction(kind: liSetFile, fileIndex: file))

    of DW_LNS_set_column:
      let col = readULeb128(data, offset)
      return some(LineInstruction(kind: liSetColumn, columnNum: col))

    of DW_LNS_negate_stmt:
      return some(LineInstruction(kind: liNegateStatement))

    of DW_LNS_set_basic_block:
      return some(LineInstruction(kind: liSetBasicBlock))

    of DW_LNS_const_add_pc:
      return some(LineInstruction(kind: liConstAddPc))

    of DW_LNS_fixed_advance_pc:
      if offset + 2 <= data.len:
        let advance = getU16LE(data, offset)
        offset += 2
        return some(LineInstruction(kind: liFixedAddPc, fixedAdvance: advance))
      else:
        return none(LineInstruction)

    of DW_LNS_set_prologue_end:
      return some(LineInstruction(kind: liSetPrologueEnd))

    of DW_LNS_set_epilogue_begin:
      return some(LineInstruction(kind: liSetEpilogueBegin))

    of DW_LNS_set_isa:
      let isa = readULeb128(data, offset)
      return some(LineInstruction(kind: liSetIsa, isa: isa))

    else:
      # Unknown standard opcode
      if opcode < header.opcodeBase and
         opcode - 1 < uint8(header.standardOpcodeLengths.len):
        let numArgs = int(header.standardOpcodeLengths[opcode - 1])
        case numArgs
        of 0:
          return some(LineInstruction(kind: liUnknownStandard0,
                                     stdOpcode: opcode))
        of 1:
          let arg = readULeb128(data, offset)
          return some(LineInstruction(kind: liUnknownStandard1,
                                     stdOpcode: opcode,
                                     stdArg: arg))
        else:
          var args: seq[uint64] = @[]
          for i in 0..<numArgs:
            args.add(readULeb128(data, offset))
          return some(LineInstruction(kind: liUnknownStandardN,
                                     stdOpcode: opcode,
                                     stdArgs: args))
      else:
        return none(LineInstruction)

# Line program state machine
type
  LineProgramState* = object
    header*: DwarfLineHeader
    row*: LineRow
    data*: seq[byte]
    offset*: int
    addressSize*: uint8
    done*: bool

proc newLineProgramState*(header: DwarfLineHeader;
                         programData: seq[byte];
                         addressSize: uint8): LineProgramState =
  ## Create a new line program state machine
  result = LineProgramState(
    header: header,
    row: newLineRow(header),
    data: programData,
    offset: 0,
    addressSize: addressSize,
    done: false
  )

proc nextRow*(state: var LineProgramState): Option[LineRow] =
  ## Execute instructions until the next row is produced
  ## Returns none when program is complete
  if state.done:
    return none(LineRow)

  # Reset from previous row
  state.row.reset(state.header)

  while state.offset < state.data.len:
    let instrOpt = parseLineInstruction(state.data, state.offset,
                                       state.header, state.addressSize)

    if instrOpt.isNone:
      state.done = true
      return none(LineRow)

    let shouldEmit = state.row.executeInstruction(instrOpt.get(),
                                                  state.header,
                                                  state.addressSize)

    if shouldEmit:
      if state.row.tombstone:
        # Skip tombstone rows
        state.row.reset(state.header)
        continue
      else:
        return some(state.row)

  state.done = true
  return none(LineRow)

#
# Inline Tests
#

when isMainModule:
  import std/unittest

  suite "DWARF Line Number State Machine":
    test "LineRow initialization":
      var header = DwarfLineHeader(
        minInstructionLength: 1,
        maxOpsPerInsn: 1,
        defaultIsStmt: 1,
        lineBase: -5,
        lineRange: 14,
        opcodeBase: 13
      )

      let row = newLineRow(header)
      check row.address == 0'u64
      check row.file == 1'u64
      check row.line == 1'u64
      check row.column == 0'u64
      check row.isStmt == true
      check row.basicBlock == false
      check row.endSequence == false

    test "Line advance positive":
      var row = LineRow(line: 10)
      row.applyLineAdvance(5)
      check row.line == 15'u64

    test "Line advance negative":
      var row = LineRow(line: 10)
      row.applyLineAdvance(-3)
      check row.line == 7'u64

    test "Line advance negative overflow":
      var row = LineRow(line: 3)
      row.applyLineAdvance(-10)
      check row.line == 0'u64

    test "Operation advance simple":
      var header = DwarfLineHeader(
        minInstructionLength: 4,
        maxOpsPerInsn: 1,
        lineRange: 14
      )
      var row = LineRow(address: 0x1000)

      row.applyOperationAdvance(3, header)
      check row.address == 0x1000'u64 + (3'u64 * 4'u64)
      check row.opIndex == 0'u64

    test "Special opcode execution":
      var header = DwarfLineHeader(
        minInstructionLength: 1,
        maxOpsPerInsn: 1,
        lineBase: -5,
        lineRange: 14,
        opcodeBase: 13
      )
      var row = LineRow(address: 0x1000, line: 10)

      # Special opcode 20: adjusted = 20 - 13 = 7
      # line_advance = 7 % 14 = 7, operation_advance = 7 / 14 = 0
      # line = 10 + (-5 + 7) = 10 + 2 = 12
      row.execSpecialOpcode(20, header)
      check row.line == 12'u64

    test "Column type":
      var row = LineRow(column: 0)
      var col = row.getColumn()
      check col.kind == false  # LeftEdge

      row.column = 42
      col = row.getColumn()
      check col.kind == true
      check col.column == 42'u64

    test "Instruction parsing - Copy":
      var header = DwarfLineHeader(opcodeBase: 13)
      var data = @[DW_LNS_copy]
      var offset = 0

      let instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome
      check instr.get().kind == liCopy
      check offset == 1

    test "Instruction parsing - AdvancePc":
      var header = DwarfLineHeader(opcodeBase: 13)
      var data: seq[byte] = @[DW_LNS_advance_pc, 0x80, 0x02]  # LEB128(256)
      var offset = 0

      let instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome
      check instr.get().kind == liAdvancePc
      check instr.get().pcAdvance == 256'u64

    test "Instruction parsing - SetAddress":
      var header = DwarfLineHeader(opcodeBase: 13)
      # Extended opcode: 0, length, DW_LNE_set_address, address
      var data: seq[byte] = @[
        0'u8,  # Extended opcode marker
        9'u8,  # Length (1 byte opcode + 8 bytes address)
        DW_LNE_set_address,
        0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00  # 0x1000 in LE
      ]
      var offset = 0

      let instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome
      check instr.get().kind == liSetAddress
      check instr.get().address == 0x1000'u64

    test "Instruction parsing - SetPrologue/Epilogue/Isa":
      var header = DwarfLineHeader(opcodeBase: 13)
      var data = @[DW_LNS_set_prologue_end]
      var offset = 0
      var instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome and instr.get().kind == liSetPrologueEnd

      data = @[DW_LNS_set_epilogue_begin]
      offset = 0
      instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome and instr.get().kind == liSetEpilogueBegin

      data = @[DW_LNS_set_isa, 0x81'u8, 0x01'u8]  # ULEB128 value 129
      offset = 0
      instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome
      check instr.get().kind == liSetIsa
      check instr.get().isa == 129'u64

    test "Instruction parsing - SetDiscriminator":
      var header = DwarfLineHeader(opcodeBase: 13)
      var data: seq[byte] = @[0'u8, 0x02'u8, DW_LNE_set_discriminator, 0x2a'u8]
      var offset = 0
      let instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome
      check instr.get().kind == liSetDiscriminator
      check instr.get().discriminator == 42'u64

    test "Instruction parsing - DefineFile DWARF4":
      var header = DwarfLineHeader(opcodeBase: 13, version: 4)
      var data: seq[byte] = @[
        0'u8,
        8'u8,
        DW_LNE_define_file,
        byte('f'), byte('o'), byte('o'), 0'u8,
        1'u8,  # dir index
        2'u8,  # timestamp
        3'u8   # size
      ]
      var offset = 0
      let instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome
      check instr.get().kind == liDefineFile
      check instr.get().fileEntry.fileName == "foo"
      check instr.get().fileEntry.directoryIndex == 1'u64
      check instr.get().fileEntry.timestamp == 2'u64
      check instr.get().fileEntry.size == 3'u64

    test "Instruction parsing - DefineFile DWARF5 treated as unknown":
      var header = DwarfLineHeader(opcodeBase: 13, version: 5)
      var data: seq[byte] = @[
        0'u8,
        8'u8,
        DW_LNE_define_file,
        byte('b'), byte('a'), byte('r'), 0'u8,
        1'u8, 2'u8, 3'u8
      ]
      var offset = 0
      let instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome
      check instr.get().kind == liUnknownExtended
      check instr.get().extOpcode == DW_LNE_define_file
      check instr.get().extData.len == 7

    test "Instruction parsing - Unknown standard opcodes":
      var header = DwarfLineHeader(opcodeBase: 20)
      header.standardOpcodeLengths = newSeq[uint8](int(header.opcodeBase))
      header.standardOpcodeLengths[12] = 0  # opcode 13 no args
      header.standardOpcodeLengths[13] = 1  # opcode 14 single arg
      header.standardOpcodeLengths[14] = 2  # opcode 15 multiple args

      var data = @[13'u8]
      var offset = 0
      var instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome
      check instr.get().kind == liUnknownStandard0
      check instr.get().stdOpcode == 13'u8

      data = @[14'u8, 0x2a'u8]
      offset = 0
      instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome
      check instr.get().kind == liUnknownStandard1
      check instr.get().stdOpcode == 14'u8
      check instr.get().stdArg == 42'u64

      data = @[15'u8, 0x01'u8, 0x02'u8]
      offset = 0
      instr = parseLineInstruction(data, offset, header, 8)
      check instr.isSome
      check instr.get().kind == liUnknownStandardN
      check instr.get().stdOpcode == 15'u8
      check instr.get().stdArgs.len == 2
      check instr.get().stdArgs[0] == 1'u64
      check instr.get().stdArgs[1] == 2'u64

    test "Row reset after Copy":
      var header = DwarfLineHeader(
        defaultIsStmt: 1,
        opcodeBase: 13
      )
      var row = LineRow(
        discriminator: 5,
        basicBlock: true,
        prologueEnd: true,
        epilogueBegin: true
      )

      row.reset(header)

      check row.discriminator == 0'u64
      check row.basicBlock == false
      check row.prologueEnd == false
      check row.epilogueBegin == false

    test "Row reset after EndSequence":
      var header = DwarfLineHeader(
        defaultIsStmt: 1,
        opcodeBase: 13,
        minInstructionLength: 1,
        maxOpsPerInsn: 1
      )
      var row = LineRow(
        address: 0x2000,
        line: 42,
        file: 5,
        endSequence: true
      )

      row.reset(header)

      check row.address == 0'u64
      check row.line == 1'u64
      check row.file == 1'u64
      check row.endSequence == false

  echo "All tests passed!"
