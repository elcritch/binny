## DWARF Parser - High-level API for parsing DWARF debug information
##
## This module provides high-level functions for parsing DWARF sections
## from ELF files, using the state machine implementation from line.nim.

import std/[algorithm, options]
import ./dwarftypes
import ./line
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

proc parseLineHeader(data: openArray[byte];
                     offset: var int;
                     addressSize: uint8;
                     lineStrData: seq[byte]): tuple[header: DwarfLineHeader,
                                                     directories: seq[string],
                                                     files: seq[tuple[name: string, dirIndex: uint32]],
                                                     programStart: int,
                                                     programEnd: int] =
  ## Parse a DWARF line number program header
  ## Returns header, directories, files, and program bounds
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
    raise newException(ValueError, "Invalid header length")

  let endOffset = offset + int(header.totalLength)

  # Version
  header.version = getU16LE(data, offset)
  offset += 2

  if header.version < 2 or header.version > 5:
    raise newException(ValueError, "Unsupported DWARF version: " & $header.version)

  # Handle DWARF 5 address/segment size
  var actualAddressSize = addressSize
  if header.version >= 5:
    actualAddressSize = data[offset]
    inc offset
    let segmentSize = data[offset]
    inc offset
    if segmentSize != 0:
      raise newException(ValueError, "Segment selectors not supported")

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

  # Read directory and file tables
  var directories: seq[string] = @[]
  var files: seq[tuple[name: string, dirIndex: uint32]] = @[]

  if header.version < 5:
    # DWARF 2-4 format
    while offset < headerEnd and data[offset] != 0:
      let dirName = readString(data, offset)
      directories.add(dirName)
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
      files.add((name: fileName, dirIndex: dirIdx))
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
        directories.add(dirPath)

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
        files.add((name: filePath, dirIndex: dirIdx))

  let programStart = headerEnd
  let programEnd = endOffset

  result = (header: header, directories: directories, files: files,
            programStart: programStart, programEnd: programEnd)

proc parseDwarfLineTable*(elf: ElfFile): DwarfLineTable =
  ## Parse the DWARF .debug_line section to extract line number information
  ## Parses all compilation units and merges their line entries using the new state machine
  let debugLineIdx = elf.findSection(".debug_line")
  if debugLineIdx < 0:
    raise newException(ValueError, "No .debug_line section found")

  let section = elf.sections[debugLineIdx]
  let data = section.data

  # Determine address size from ELF header
  let addressSize = if elf.header.e_ident[EI_CLASS] == ELFCLASS64: 8'u8 else: 4'u8

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

    # Parse header
    let (header, directories, files, programStart, programEnd) =
      try:
        parseLineHeader(data, offset, addressSize, lineStrData)
      except ValueError:
        # Skip invalid compilation unit
        break

    # Store the first header we encounter
    if result.header.version == 0:
      result.header = header

    # Track global file/dir indices
    let fileIndexOffset = uint32(result.files.len)
    let dirIndexOffset = uint32(result.directories.len)

    # Adjust directory indices in files and merge
    var adjustedFiles: seq[tuple[name: string, dirIndex: uint32]] = @[]
    for file in files:
      if header.version < 5:
        # DWARF 2-4: directory index 0 means current directory
        let globalDirIdx = if file.dirIndex > 0: file.dirIndex + dirIndexOffset else: 0
        adjustedFiles.add((name: file.name, dirIndex: globalDirIdx))
      else:
        # DWARF 5: directory indices are 0-based
        let globalDirIdx = file.dirIndex + dirIndexOffset + 1
        adjustedFiles.add((name: file.name, dirIndex: globalDirIdx))

    result.directories.add(directories)
    result.files.add(adjustedFiles)

    # Extract program data
    if programStart < data.len and programEnd <= data.len and programStart < programEnd:
      let programData = data[programStart..<programEnd]

      # Use the new state machine to execute the line program
      var state = newLineProgramState(header, programData, addressSize)

      var rowOpt = state.nextRow()
      while isSome(rowOpt):
        let row = get(rowOpt)

        # Convert LineRow to DwarfLineEntry with adjusted file indices
        result.entries.add(DwarfLineEntry(
          address: row.address,
          file: uint32(row.file) + fileIndexOffset,
          line: uint32(row.line),
          column: uint32(row.column),
          discriminator: uint32(row.discriminator)
        ))

        # Get next row
        rowOpt = state.nextRow()

    # Move to next compilation unit
    sectionOffset = programEnd

  # Sort table by address
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
