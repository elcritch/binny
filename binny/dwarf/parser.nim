import std/algorithm
import ./dwarftypes
import ../utils
import ../elfparser

proc readString(data: openArray[byte]; offset: int): string =
  var i = offset
  result = ""
  while i < data.len and data[i] != 0:
    result.add char(data[i])
    inc i

proc readDwarfForm(data: openArray[byte]; offset: var int; form: uint8; lineStrSection: openArray[byte] = []): string =
  ## Read a value from DWARF data according to the form
  ## For string forms, returns the string; for numeric forms, returns empty string
  case form
  of DW_FORM_string:
    result = readString(data, offset)
    offset += result.len + 1
  of DW_FORM_strp:
    # String pointer into .debug_str - skip for now
    offset += 4
    result = ""
  of DW_FORM_line_strp:
    # String pointer into .debug_line_str
    let strOffset = int(getU32LE(data, offset))
    offset += 4
    if lineStrSection.len > 0 and strOffset < lineStrSection.len:
      result = readString(lineStrSection, strOffset)
    else:
      result = ""
  of DW_FORM_data1:
    result = ""
    offset += 1
  of DW_FORM_udata:
    discard readULeb128(data, offset)
    result = ""
  else:
    # Unknown form, try to skip
    result = ""

proc parseDwarfLineTable*(elf: ElfFile): DwarfLineTable =
  ## Parse the DWARF .debug_line section to extract line number information
  ## Parses all compilation units and merges their line entries
  let debugLineIdx = elf.findSection(".debug_line")
  if debugLineIdx < 0:
    raise newException(ValueError, "No .debug_line section found")

  let section = elf.sections[debugLineIdx]
  let data = section.data

  # Try to get .debug_line_str section for DWARF 5
  var lineStrData: seq[byte] = @[]
  let lineStrIdx = elf.findSection(".debug_line_str")
  if lineStrIdx >= 0:
    lineStrData = elf.sections[lineStrIdx].data

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

    # Read directory table (DWARF 2-4 and 5+)
    var localDirectories: seq[string] = @[]
    var localFiles: seq[tuple[name: string, dirIndex: uint32]] = @[]
    let fileIndexOffset = uint32(result.files.len)
    let dirIndexOffset = uint32(result.directories.len)

    if header.version < 5:
      # DWARF 2-4 format
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
        # Adjust directory index to be global
        let globalDirIdx = if dirIdx > 0: dirIdx + dirIndexOffset else: 0
        localFiles.add((name: fileName, dirIndex: globalDirIdx))
    else:
      # DWARF 5 format
      # Read directory entry format description
      let dirFormatCount = data[offset]
      inc offset

      var dirFormats: seq[tuple[contentType: uint8, form: uint8]] = @[]
      for i in 0..<int(dirFormatCount):
        let contentType = uint8(readULeb128(data, offset))
        let form = uint8(readULeb128(data, offset))
        dirFormats.add((contentType: contentType, form: form))

      # Read directories
      let dirCount = readULeb128(data, offset)
      for i in 0..<int(dirCount):
        var dirPath = ""
        for fmt in dirFormats:
          if fmt.contentType == DW_LNCT_path:
            dirPath = readDwarfForm(data, offset, fmt.form, lineStrData)
          else:
            discard readDwarfForm(data, offset, fmt.form, lineStrData)
        if dirPath.len > 0:
          localDirectories.add(dirPath)

      # Read file entry format description
      let fileFormatCount = data[offset]
      inc offset

      var fileFormats: seq[tuple[contentType: uint8, form: uint8]] = @[]
      for i in 0..<int(fileFormatCount):
        let contentType = uint8(readULeb128(data, offset))
        let form = uint8(readULeb128(data, offset))
        fileFormats.add((contentType: contentType, form: form))

      # Read files
      let fileCount = readULeb128(data, offset)
      for i in 0..<int(fileCount):
        var filePath = ""
        var dirIdx: uint32 = 0
        for fmt in fileFormats:
          if fmt.contentType == DW_LNCT_path:
            filePath = readDwarfForm(data, offset, fmt.form, lineStrData)
          elif fmt.contentType == DW_LNCT_directory_index:
            let val = readULeb128(data, offset)
            dirIdx = uint32(val)
          else:
            discard readDwarfForm(data, offset, fmt.form, lineStrData)
        if filePath.len > 0:
          # For DWARF 5, directory indices are 0-based (0 is valid)
          # We always adjust by the offset
          let globalDirIdx = dirIdx + dirIndexOffset + 1  # +1 because DWARF uses 1-based in file table lookup
          localFiles.add((name: filePath, dirIndex: globalDirIdx))

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

  # Sort table
  result.entries.sort(proc(a, b: DwarfLineEntry): int = cmp(a.address, b.address))

proc findLineInfo*(lineTable: DwarfLineTable; address: uint64): tuple[file: string, line: uint32] =
  ## Find source file and line number for a given address (like addr2line)

  # Binary search for the address
  var bestMatch: DwarfLineEntry
  var found = false

  for entry in lineTable.entries:
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
