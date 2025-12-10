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

# Column type for line number information
type
  ColumnType* = object
    case kind*: bool
    of false:  # LeftEdge - statement begins at start of line
      discard
    of true:   # Column number (1-based)
      column*: uint64

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
    liUnknownStandard      # Unknown standard opcode
    liUnknownExtended      # Unknown extended opcode

  LineInstruction* = object
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
      fileName*: string
      dirIndex*: uint32
    of liSetDiscriminator:
      discriminator*: uint64
    of liUnknownStandard:
      stdOpcode*: uint8
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
                           header: DwarfLineHeader): bool =
  ## Apply operation advance (step 2 of section 6.2.5.1)
  ## Returns false on overflow error
  if row.tombstone:
    return true

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
    return false

  row.address += addressAdvance
  return true

proc adjustOpcode*(opcode: uint8; header: DwarfLineHeader): uint8 {.inline.} =
  ## Adjust opcode by subtracting opcode_base
  opcode - header.opcodeBase

proc execSpecialOpcode*(row: var LineRow;
                        opcode: uint8;
                        header: DwarfLineHeader): bool =
  ## Execute a special opcode (section 6.2.5.1)
  ## Returns false on error
  let adjustedOpcode = adjustOpcode(opcode, header)

  if header.lineRange == 0:
    return false

  let lineAdvance = adjustedOpcode mod header.lineRange
  let operationAdvance = adjustedOpcode div header.lineRange

  # Step 1: Apply line advance
  let lineBase = int64(header.lineBase)
  row.applyLineAdvance(lineBase + int64(lineAdvance))

  # Step 2: Apply operation advance
  result = row.applyOperationAdvance(uint64(operationAdvance), header)

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
    if not row.execSpecialOpcode(instruction.opcode, header):
      return false
    return true

  of liCopy:
    return true

  of liAdvancePc:
    discard row.applyOperationAdvance(instruction.pcAdvance, header)
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
    discard row.applyOperationAdvance(uint64(operationAdvance), header)
    return false

  of liFixedAddPc:
    if not row.tombstone:
      row.address += uint64(instruction.fixedAdvance)
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

  of liDefineFile, liUnknownStandard, liUnknownExtended:
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
    # Extended opcode
    let extLen = readULeb128(data, offset)
    if offset >= data.len or offset + int(extLen) > data.len:
      return none(LineInstruction)

    let extOpcode = data[offset]
    inc offset

    case extOpcode
    of DW_LNE_end_sequence:
      return some(LineInstruction(kind: liEndSequence))

    of DW_LNE_set_address:
      if addressSize == 8 and offset + 8 <= data.len:
        let addrValue = getU64LE(data, offset)
        offset += 8
        return some(LineInstruction(kind: liSetAddress, address: addrValue))
      elif addressSize == 4 and offset + 4 <= data.len:
        let addrValue = uint64(getU32LE(data, offset))
        offset += 4
        return some(LineInstruction(kind: liSetAddress, address: addrValue))
      else:
        return none(LineInstruction)

    of DW_LNE_set_discriminator:
      let disc = readULeb128(data, offset)
      return some(LineInstruction(kind: liSetDiscriminator, discriminator: disc))

    else:
      # Unknown extended opcode - skip it
      offset += int(extLen) - 1
      return some(LineInstruction(kind: liUnknownExtended,
                                 extOpcode: extOpcode,
                                 extData: @[]))

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

    else:
      # Unknown standard opcode
      if opcode < header.opcodeBase and
         opcode - 1 < uint8(header.standardOpcodeLengths.len):
        let numArgs = int(header.standardOpcodeLengths[opcode - 1])
        var args: seq[uint64] = @[]
        for i in 0..<numArgs:
          args.add(readULeb128(data, offset))
        return some(LineInstruction(kind: liUnknownStandard,
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

      let ok = row.applyOperationAdvance(3, header)
      check ok == true
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
      let ok = row.execSpecialOpcode(20, header)
      check ok == true
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
