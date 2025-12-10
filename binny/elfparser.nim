import std/strformat
import ./utils
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

proc listSections*(elf: ElfFile): seq[string] =
  result = @[]
  for section in elf.sections:
    if section.name.len > 0:
      result.add(section.name)
