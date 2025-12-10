import std/[strformat, tables, algorithm]
import ./demangler

# ELF constants and structures based on System V ABI
const
  ELFMAG0* = 0x7F'u8
  ELFMAG1* = ord('E')
  ELFMAG2* = ord('L')
  ELFMAG3* = ord('F')
  EI_CLASS* = 4
  EI_DATA* = 5
  EI_VERSION* = 6

  ELFCLASS32* = 1'u8
  ELFCLASS64* = 2'u8
  ELFDATA2LSB* = 1'u8
  ELFDATA2MSB* = 2'u8
  EV_CURRENT* = 1'u8

  ET_EXEC* = 2'u16
  ET_DYN* = 3'u16

  SHT_NULL* = 0'u32
  SHT_PROGBITS* = 1'u32
  SHT_SYMTAB* = 2'u32
  SHT_STRTAB* = 3'u32
  SHT_DYNSYM* = 11'u32

type
  ElfIdent* = array[16, uint8]

  ElfHeader64* {.packed.} = object
    e_ident*: ElfIdent
    e_type*: uint16
    e_machine*: uint16
    e_version*: uint32
    e_entry*: uint64
    e_phoff*: uint64
    e_shoff*: uint64
    e_flags*: uint32
    e_ehsize*: uint16
    e_phentsize*: uint16
    e_phnum*: uint16
    e_shentsize*: uint16
    e_shnum*: uint16
    e_shstrndx*: uint16

  SectionHeader64* {.packed.} = object
    sh_name*: uint32
    sh_type*: uint32
    sh_flags*: uint64
    sh_addr*: uint64
    sh_offset*: uint64
    sh_size*: uint64
    sh_link*: uint32
    sh_info*: uint32
    sh_addralign*: uint64
    sh_entsize*: uint64

  Symbol64* {.packed.} = object
    st_name*: uint32
    st_info*: uint8
    st_other*: uint8
    st_shndx*: uint16
    st_value*: uint64
    st_size*: uint64

  ElfSection* = object
    name*: string
    sectionType*: uint32
    address*: uint64
    offset*: uint64
    size*: uint64
    data*: seq[byte]

  ElfSymbol* = object
    name*: string
    value*: uint64
    size*: uint64
    sectionIndex*: uint16

  ElfFile* = object
    header*: ElfHeader64
    sections*: seq[ElfSection]
    symbols*: seq[ElfSymbol]
    stringTable*: seq[byte]

  # DWARF Line Number Info structures
  DwarfLineHeader* = object
    totalLength*: uint64
    version*: uint16
    prologueLength*: uint64
    minInstructionLength*: uint8
    maxOpsPerInsn*: uint8
    defaultIsStmt*: uint8
    lineBase*: int8
    lineRange*: uint8
    opcodeBase*: uint8
    standardOpcodeLengths*: seq[uint8]

  DwarfLineEntry* = object
    address*: uint64
    file*: uint32
    line*: uint32
    column*: uint32
    discriminator*: uint32

  DwarfLineTable* = object
    header*: DwarfLineHeader
    directories*: seq[string]
    files*: seq[tuple[name: string, dirIndex: uint32]]
    entries*: seq[DwarfLineEntry]

# DWARF Line Number Program opcodes
const
  DW_LNS_extended_op = 0'u8
  DW_LNS_copy = 1'u8
  DW_LNS_advance_pc = 2'u8
  DW_LNS_advance_line = 3'u8
  DW_LNS_set_file = 4'u8
  DW_LNS_set_column = 5'u8
  DW_LNS_negate_stmt = 6'u8
  DW_LNS_set_basic_block = 7'u8
  DW_LNS_const_add_pc = 8'u8
  DW_LNS_fixed_advance_pc = 9'u8

  DW_LNE_end_sequence = 1'u8
  DW_LNE_set_address = 2'u8
  DW_LNE_define_file = 3'u8
  DW_LNE_set_discriminator = 4'u8
  DW_LNE_HP_source_file_correlation = 0x80'u8

proc getU16LE(data: openArray[byte]; offset: int): uint16 =
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc getU32LE(data: openArray[byte]; offset: int): uint32 =
  uint32(data[offset]) or (uint32(data[offset + 1]) shl 8) or
  (uint32(data[offset + 2]) shl 16) or (uint32(data[offset + 3]) shl 24)

proc getU64LE(data: openArray[byte]; offset: int): uint64 =
  uint64(data[offset]) or (uint64(data[offset + 1]) shl 8) or
  (uint64(data[offset + 2]) shl 16) or (uint64(data[offset + 3]) shl 24) or
  (uint64(data[offset + 4]) shl 32) or (uint64(data[offset + 5]) shl 40) or
  (uint64(data[offset + 6]) shl 48) or (uint64(data[offset + 7]) shl 56)

proc readString(data: openArray[byte]; offset: int): string =
  var i = offset
  result = ""
  while i < data.len and data[i] != 0:
    result.add char(data[i])
    inc i

proc parseElfHeader*(data: openArray[byte]): ElfHeader64 =
  if data.len < sizeof(ElfHeader64):
    raise newException(ValueError, "File too small for ELF header")

  # Check ELF magic
  if data[0] != ELFMAG0 or data[1] != ELFMAG1.uint8 or
     data[2] != ELFMAG2.uint8 or data[3] != ELFMAG3.uint8:
    raise newException(ValueError, "Not a valid ELF file")

  # Check for 64-bit little endian
  if data[EI_CLASS] != ELFCLASS64:
    raise newException(ValueError, "Only 64-bit ELF files supported")

  if data[EI_DATA] != ELFDATA2LSB:
    raise newException(ValueError, "Only little endian ELF files supported")

  # Copy ident array
  for i in 0..15:
    result.e_ident[i] = data[i]

  # Parse rest of header (assuming little endian)
  result.e_type = getU16LE(data, 16)
  result.e_machine = getU16LE(data, 18)
  result.e_version = getU32LE(data, 20)
  result.e_entry = getU64LE(data, 24)
  result.e_phoff = getU64LE(data, 32)
  result.e_shoff = getU64LE(data, 40)
  result.e_flags = getU32LE(data, 48)
  result.e_ehsize = getU16LE(data, 52)
  result.e_phentsize = getU16LE(data, 54)
  result.e_phnum = getU16LE(data, 56)
  result.e_shentsize = getU16LE(data, 58)
  result.e_shnum = getU16LE(data, 60)
  result.e_shstrndx = getU16LE(data, 62)

proc parseSectionHeader*(data: openArray[byte]; offset: int): SectionHeader64 =
  if offset + sizeof(SectionHeader64) > data.len:
    raise newException(ValueError, "Invalid section header offset")

  result.sh_name = getU32LE(data, offset)
  result.sh_type = getU32LE(data, offset + 4)
  result.sh_flags = getU64LE(data, offset + 8)
  result.sh_addr = getU64LE(data, offset + 16)
  result.sh_offset = getU64LE(data, offset + 24)
  result.sh_size = getU64LE(data, offset + 32)
  result.sh_link = getU32LE(data, offset + 40)
  result.sh_info = getU32LE(data, offset + 44)
  result.sh_addralign = getU64LE(data, offset + 48)
  result.sh_entsize = getU64LE(data, offset + 56)

proc parseSymbol*(data: openArray[byte]; offset: int): Symbol64 =
  if offset + sizeof(Symbol64) > data.len:
    raise newException(ValueError, "Invalid symbol offset")

  result.st_name = getU32LE(data, offset)
  result.st_info = data[offset + 4]
  result.st_other = data[offset + 5]
  result.st_shndx = getU16LE(data, offset + 6)
  result.st_value = getU64LE(data, offset + 8)
  result.st_size = getU64LE(data, offset + 16)

proc parseElf*(filePath: string): ElfFile =
  let fileData = readFile(filePath)
  let data = cast[seq[byte]](fileData)

  result.header = parseElfHeader(data)

  # Parse section headers
  let sectionOffset = int(result.header.e_shoff)
  let sectionSize = int(result.header.e_shentsize)
  let numSections = int(result.header.e_shnum)
  let shstrndx = int(result.header.e_shstrndx)

  # First pass: read all section headers
  var sectionHeaders = newSeq[SectionHeader64](numSections)
  for i in 0..<numSections:
    let offset = sectionOffset + i * sectionSize
    sectionHeaders[i] = parseSectionHeader(data, offset)

  # Get string table section for section names
  var shstrtab: seq[byte]
  if shstrndx < numSections:
    let shstrtabHdr = sectionHeaders[shstrndx]
    let start = int(shstrtabHdr.sh_offset)
    let size = int(shstrtabHdr.sh_size)
    if start + size <= data.len:
      shstrtab = data[start..<start + size]

  # Second pass: create sections with names and data
  result.sections = newSeq[ElfSection](numSections)
  var symtabSection = -1
  var strtabSection = -1

  for i in 0..<numSections:
    let hdr = sectionHeaders[i]
    var section = ElfSection()

    # Get section name
    if shstrtab.len > 0 and int(hdr.sh_name) < shstrtab.len:
      section.name = readString(shstrtab, int(hdr.sh_name))
    else:
      section.name = fmt"section_{i}"

    section.sectionType = hdr.sh_type
    section.address = hdr.sh_addr
    section.offset = hdr.sh_offset
    section.size = hdr.sh_size

    # Read section data
    if hdr.sh_offset > 0 and hdr.sh_size > 0:
      let start = int(hdr.sh_offset)
      let size = int(hdr.sh_size)
      if start + size <= data.len:
        section.data = data[start..<start + size]

    result.sections[i] = section

    # Track symbol and string table sections
    if hdr.sh_type == SHT_SYMTAB:
      symtabSection = i
    elif hdr.sh_type == SHT_STRTAB and section.name == ".strtab":
      strtabSection = i

  # Parse symbols if we have a symbol table
  if symtabSection >= 0 and strtabSection >= 0:
    let symtab = result.sections[symtabSection]
    let strtab = result.sections[strtabSection]
    result.stringTable = strtab.data

    let numSymbols = int(symtab.size) div sizeof(Symbol64)
    result.symbols = newSeq[ElfSymbol](numSymbols)

    for i in 0..<numSymbols:
      let offset = i * sizeof(Symbol64)
      let sym = parseSymbol(symtab.data, offset)

      var elfSym = ElfSymbol()
      elfSym.value = sym.st_value
      elfSym.size = sym.st_size
      elfSym.sectionIndex = sym.st_shndx

      # Get symbol name from string table
      if int(sym.st_name) < strtab.data.len:
        elfSym.name = readString(strtab.data, int(sym.st_name))

      result.symbols[i] = elfSym

proc findSection*(elf: ElfFile; name: string): int =
  for i, section in elf.sections:
    if section.name == name:
      return i
  return -1

proc getSframeSection*(elf: ElfFile): (seq[byte], uint64) =
  let idx = elf.findSection(".sframe")
  if idx < 0:
    raise newException(ValueError, "No .sframe section found")

  let section = elf.sections[idx]
  result = (section.data, section.address)

proc getTextSection*(elf: ElfFile): (seq[byte], uint64) =
  let idx = elf.findSection(".text")
  if idx < 0:
    raise newException(ValueError, "No .text section found")

  let section = elf.sections[idx]
  result = (section.data, section.address)

proc getFunctionSymbols*(elf: ElfFile): seq[ElfSymbol] =
  result = @[]

  for sym in elf.symbols:
    # Include all symbols with size > 0 to get better coverage
    # This includes compiler-generated functions and internal symbols
    if sym.size > 0 and sym.name.len > 0:
      result.add(sym)

proc getDemangledFunctionSymbols*(elf: ElfFile): seq[ElfSymbol] =
  ## Get function symbols with demangled names
  result = @[]

  for sym in elf.getFunctionSymbols():
    var demangledSym = sym
    demangledSym.name = demangle(sym.name)
    result.add(demangledSym)

# LEB128 decoding (used in DWARF)
proc readULeb128(data: openArray[byte]; offset: var int): uint64 =
  result = 0
  var shift = 0
  while offset < data.len:
    let b = data[offset]
    inc offset
    result = result or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0:
      break
    shift += 7

proc readSLeb128(data: openArray[byte]; offset: var int): int64 =
  result = 0
  var shift = 0
  var b: byte
  while offset < data.len:
    b = data[offset]
    inc offset
    result = result or (int64(b and 0x7F) shl shift)
    shift += 7
    if (b and 0x80) == 0:
      break

  # Sign extend if needed
  if shift < 64 and (b and 0x40) != 0:
    result = result or (not 0'i64 shl shift)

proc parseDwarfLineTable*(elf: ElfFile): DwarfLineTable =
  ## Parse the DWARF .debug_line section to extract line number information
  ## Parses all compilation units and merges their line entries
  let debugLineIdx = elf.findSection(".debug_line")
  if debugLineIdx < 0:
    raise newException(ValueError, "No .debug_line section found")

  let section = elf.sections[debugLineIdx]
  let data = section.data

  result.directories = @[]
  result.files = @[]
  result.entries = @[]

  var sectionOffset = 0

  # Parse all compilation units in the .debug_line section
  while sectionOffset < data.len - 4:
    var offset = sectionOffset

    # Read header for this compilation unit
    var header: DwarfLineHeader

    # Read total length (can be 32 or 64 bit)
    let initialLength = getU32LE(data, offset)
    offset += 4

    var offsetSize = 4
    if initialLength == 0xffffffff'u32:
      # 64-bit DWARF format
      header.totalLength = getU64LE(data, offset)
      offset += 8
      offsetSize = 8
    else:
      header.totalLength = initialLength

    if header.totalLength == 0:
      break  # End of compilation units

    let endOffset = offset + int(header.totalLength)
    if endOffset > data.len:
      break  # Invalid length, stop parsing

    # Version
    header.version = getU16LE(data, offset)
    offset += 2

    if header.version < 2 or header.version > 5:
      # Skip unsupported versions
      sectionOffset = endOffset
      continue

    # Handle DWARF 5 address/segment size
    if header.version >= 5:
      offset += 1  # Skip address size
      let segmentSize = data[offset]
      inc offset
      if segmentSize != 0:
        sectionOffset = endOffset
        continue

    # Prologue length
    if offsetSize == 8:
      header.prologueLength = getU64LE(data, offset)
      offset += 8
    else:
      header.prologueLength = uint64(getU32LE(data, offset))
      offset += 4

    let headerEnd = offset + int(header.prologueLength)

    # Instruction lengths
    header.minInstructionLength = data[offset]
    inc offset

    if header.version >= 4:
      header.maxOpsPerInsn = data[offset]
      inc offset
    else:
      header.maxOpsPerInsn = 1

    header.defaultIsStmt = data[offset]
    inc offset

    header.lineBase = cast[int8](data[offset])
    inc offset

    header.lineRange = data[offset]
    inc offset

    header.opcodeBase = data[offset]
    inc offset

    # Standard opcode lengths
    header.standardOpcodeLengths = newSeq[uint8](header.opcodeBase)
    header.standardOpcodeLengths[0] = 1
    for i in 1 ..< int(header.opcodeBase):
      header.standardOpcodeLengths[i] = data[offset]
      inc offset

    # Store the first header we encounter
    if result.header.version == 0:
      result.header = header

    # Read directory table (DWARF 2-4)
    var localDirectories: seq[string] = @[]
    var localFiles: seq[tuple[name: string, dirIndex: uint32]] = @[]
    let fileIndexOffset = uint32(result.files.len)

    if header.version < 5:
      while offset < headerEnd and data[offset] != 0:
        let dirName = readString(data, offset)
        localDirectories.add(dirName)
        offset += dirName.len + 1
      if offset < headerEnd:
        inc offset  # Skip null terminator

      # Read file table
      while offset < headerEnd and data[offset] != 0:
        let fileName = readString(data, offset)
        offset += fileName.len + 1
        let dirIdx = uint32(readULeb128(data, offset))
        discard readULeb128(data, offset)  # mod time
        discard readULeb128(data, offset)  # file size
        localFiles.add((name: fileName, dirIndex: dirIdx))

    # Merge directories and files into result
    result.directories.add(localDirectories)
    result.files.add(localFiles)

    offset = headerEnd

    # Decode line number program for this compilation unit
    while offset < endOffset and offset < data.len:
      # State machine registers
      var address: uint64 = 0
      var fileNum: uint32 = 1
      var line: uint32 = 1
      var column: uint32 = 0
      var discriminator: uint32 = 0
      var isStmt = header.defaultIsStmt != 0
      var endSequence = false

      while not endSequence and offset < endOffset:
        let opcode = data[offset]
        inc offset

        if opcode >= header.opcodeBase:
          # Special opcode
          let adjustedOpcode = opcode - header.opcodeBase
          if header.lineRange > 0:
            let addrIncr = uint64(adjustedOpcode div header.lineRange) *
                           uint64(header.minInstructionLength)
            address += addrIncr
            line = uint32(int32(line) + int32(header.lineBase) +
                         int32(adjustedOpcode mod header.lineRange))

            # Add entry
            result.entries.add(DwarfLineEntry(
              address: address,
              file: fileNum + fileIndexOffset,
              line: line,
              column: column,
              discriminator: discriminator
            ))
            discriminator = 0

        elif opcode == DW_LNS_extended_op:
          let extLen = readULeb128(data, offset)
          let extOp = data[offset]
          inc offset

          case extOp
          of DW_LNE_end_sequence:
            endSequence = true
            result.entries.add(DwarfLineEntry(
              address: address,
              file: fileNum + fileIndexOffset,
              line: line,
              column: column,
              discriminator: discriminator
            ))
          of DW_LNE_set_address:
            if elf.header.e_ident[EI_CLASS] == ELFCLASS64:
              address = getU64LE(data, offset)
              offset += 8
            else:
              address = uint64(getU32LE(data, offset))
              offset += 4
          of DW_LNE_set_discriminator:
            discriminator = uint32(readULeb128(data, offset))
          of DW_LNE_HP_source_file_correlation:
            offset += int(extLen) - 1
          else:
            offset += int(extLen) - 1

        elif opcode == DW_LNS_copy:
          result.entries.add(DwarfLineEntry(
            address: address,
            file: fileNum + fileIndexOffset,
            line: line,
            column: column,
            discriminator: discriminator
          ))
          discriminator = 0

        elif opcode == DW_LNS_advance_pc:
          let addrIncr = readULeb128(data, offset) * uint64(header.minInstructionLength)
          address += addrIncr

        elif opcode == DW_LNS_advance_line:
          line = uint32(int32(line) + int32(readSLeb128(data, offset)))

        elif opcode == DW_LNS_set_file:
          fileNum = uint32(readULeb128(data, offset))

        elif opcode == DW_LNS_set_column:
          column = uint32(readULeb128(data, offset))

        elif opcode == DW_LNS_negate_stmt:
          isStmt = not isStmt

        elif opcode == DW_LNS_set_basic_block:
          discard  # We don't track basic blocks

        elif opcode == DW_LNS_const_add_pc:
          if header.lineRange > 0:
            let adjustedOpcode = 255 - header.opcodeBase
            let addrIncr = uint64(adjustedOpcode div header.lineRange) *
                           uint64(header.minInstructionLength)
            address += addrIncr

        elif opcode == DW_LNS_fixed_advance_pc:
          address += uint64(getU16LE(data, offset))
          offset += 2

        else:
          # Unknown opcode - skip operands
          if opcode < header.opcodeBase:
            for i in 0 ..< int(header.standardOpcodeLengths[opcode]):
              discard readULeb128(data, offset)

      if endSequence:
        break

    # Move to next compilation unit
    sectionOffset = endOffset

proc findLineInfo*(elf: ElfFile; address: uint64): tuple[file: string, line: uint32] =
  ## Find source file and line number for a given address (like addr2line)
  let lineTable = elf.parseDwarfLineTable()

  # Sort entries by address
  var sortedEntries = lineTable.entries
  sortedEntries.sort(proc(a, b: DwarfLineEntry): int = cmp(a.address, b.address))

  # Binary search for the address
  var bestMatch: DwarfLineEntry
  var found = false

  for entry in sortedEntries:
    if entry.address <= address:
      bestMatch = entry
      found = true
    else:
      break

  if not found:
    return (file: "??", line: 0)

  # Get file name
  var fileName = "??"
  if bestMatch.file > 0 and bestMatch.file <= uint32(lineTable.files.len):
    let fileEntry = lineTable.files[bestMatch.file - 1]
    fileName = fileEntry.name

    # Prepend directory if available and filename is not already absolute
    if fileName.len > 0 and fileName[0] != '/' and
       fileEntry.dirIndex > 0 and fileEntry.dirIndex <= uint32(lineTable.directories.len):
      let dirName = lineTable.directories[fileEntry.dirIndex - 1]
      if dirName.len > 0:
        fileName = dirName & "/" & fileName

  return (file: fileName, line: bestMatch.line)

proc listSections*(elf: ElfFile): seq[string] =
  result = @[]
  for section in elf.sections:
    if section.name.len > 0:
      result.add(section.name)
