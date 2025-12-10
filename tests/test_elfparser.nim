import std/unittest
import binny/elfparser
import binny/demangler # For getDemangledFunctionSymbols

suite "ELF Parser Tests":

  test "Parse ELF Header":
    var header: seq[byte] = @[]
    header.add(ELFMAG0)
    header.add(byte(ELFMAG1))
    header.add(byte(ELFMAG2))
    header.add(byte(ELFMAG3))
    header.add(ELFCLASS64)
    header.add(ELFDATA2LSB)
    header.add(EV_CURRENT)
    header.add(newSeq[byte](9))

    header.add(@[0x02'u8, 0x00]) # e_type = ET_EXEC
    header.add(@[0x3E'u8, 0x00]) # e_machine = x86-64 (62)
    header.add(@[0x01'u8, 0x00, 0x00, 0x00]) # e_version = 1
    header.add(@[0x80'u8, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00]) # e_entry = 0x400080
    header.add(@[0x40'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) # e_phoff = 64
    header.add(@[0x00'u8, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) # e_shoff = 0x1000
    header.add(@[0x00'u8, 0x00, 0x00, 0x00]) # e_flags = 0
    header.add(@[0x40'u8, 0x00]) # e_ehsize = 64
    header.add(@[0x38'u8, 0x00]) # e_phentsize = 56
    header.add(@[0x03'u8, 0x00]) # e_phnum = 3
    header.add(@[0x40'u8, 0x00]) # e_shentsize = 64
    header.add(@[0x05'u8, 0x00]) # e_shnum = 5
    header.add(@[0x04'u8, 0x00]) # e_shstrndx = 4

    let parsedHeader = parseElfHeader(header)
    check parsedHeader.e_ident[0] == ELFMAG0
    check parsedHeader.e_type == ET_EXEC
    check parsedHeader.e_machine == 62
    check parsedHeader.e_version == 1
    check parsedHeader.e_entry == 0x400080
    check parsedHeader.e_phoff == 64
    check parsedHeader.e_shoff == 0x1000
    check parsedHeader.e_flags == 0
    check parsedHeader.e_ehsize == 64
    check parsedHeader.e_phentsize == 56
    check parsedHeader.e_phnum == 3
    check parsedHeader.e_shentsize == 64
    check parsedHeader.e_shnum == 5
    check parsedHeader.e_shstrndx == 4

    # Test invalid headers
    var badHeader = @header
    badHeader[0] = 0x00
    expect ValueError:
      discard parseElfHeader(badHeader)
    
    badHeader = @header
    badHeader[EI_CLASS] = ELFCLASS32
    expect ValueError:
      discard parseElfHeader(badHeader)

    let shortHeader = header[0..30]
    expect ValueError:
      discard parseElfHeader(shortHeader)

  test "Parse Section Header":
    var sectionHeader: seq[byte] = @[]
    sectionHeader.add(@[0x01'u8, 0x00, 0x00, 0x00]) # sh_name = 1
    sectionHeader.add(@[0x01'u8, 0x00, 0x00, 0x00]) # sh_type = SHT_PROGBITS
    sectionHeader.add(@[0x06'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) # sh_flags = 6
    sectionHeader.add(@[0x00'u8, 0x01, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00]) # sh_addr = 0x400100
    sectionHeader.add(@[0x00'u8, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) # sh_offset = 0x100
    sectionHeader.add(@[0x34'u8, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) # sh_size = 0x1234
    sectionHeader.add(@[0x00'u8, 0x00, 0x00, 0x00]) # sh_link = 0
    sectionHeader.add(@[0x00'u8, 0x00, 0x00, 0x00]) # sh_info = 0
    sectionHeader.add(@[0x10'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) # sh_addralign = 16
    sectionHeader.add(@[0x00'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) # sh_entsize = 0

    let parsed = parseSectionHeader(sectionHeader, 0)
    check parsed.sh_name == 1
    check parsed.sh_type == SHT_PROGBITS
    check parsed.sh_flags == 6
    check parsed.sh_addr == 0x400100
    check parsed.sh_offset == 0x100
    check parsed.sh_size == 0x1234
    check parsed.sh_link == 0
    check parsed.sh_info == 0
    check parsed.sh_addralign == 16
    check parsed.sh_entsize == 0

  test "Parse Symbol":
    var symbol: seq[byte] = @[]
    symbol.add(@[0x0A'u8, 0x00, 0x00, 0x00]) # st_name = 10
    symbol.add(@[0x12'u8]) # st_info = 18 (GLOBAL | FUNC)
    symbol.add(@[0x00'u8]) # st_other = 0
    symbol.add(@[0x01'u8, 0x00]) # st_shndx = 1
    symbol.add(@[0x00'u8, 0x02, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00]) # st_value = 0x400200
    symbol.add(@[0x80'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) # st_size = 128

    let parsed = parseSymbol(symbol, 0)
    check parsed.st_name == 10
    check parsed.st_info == 18
    check parsed.st_other == 0
    check parsed.st_shndx == 1
    check parsed.st_value == 0x400200
    check parsed.st_size == 128

  test "ELF File Helpers":
    var elfFile = ElfFile()
    elfFile.sections = @[
      ElfSection(name: ".text", sectionType: SHT_PROGBITS, address: 0x1000, size: 100),
      ElfSection(name: ".data", sectionType: SHT_PROGBITS, address: 0x2000, size: 200),
      ElfSection(name: ".sframe", sectionType: SHT_PROGBITS, address: 0x3000, size: 50, data: @[0x01'u8, 0x02'u8]),
    ]
    elfFile.symbols = @[
      ElfSymbol(name: "_Z3foov", value: 0x1010, size: 20, sectionIndex: 1),
      ElfSymbol(name: "bar", value: 0x1030, size: 30, sectionIndex: 1),
      ElfSymbol(name: "data_var", value: 0x2010, size: 4, sectionIndex: 2),
      ElfSymbol(name: "ignored", value: 0x1050, size: 0, sectionIndex: 1),
    ]

    check elfFile.findSection(".text") == 0
    check elfFile.findSection(".data") == 1
    check elfFile.findSection(".nonexistent") == -1

    let (sframeData, sframeAddr) = elfFile.getSframeSection()
    check sframeData == @[0x01'u8, 0x02'u8]
    check sframeAddr == 0x3000

    expect ValueError:
      var emptyElf = ElfFile()
      discard emptyElf.getSframeSection()

    let funcSyms = elfFile.getFunctionSymbols()
    check funcSyms.len == 3
    check funcSyms[0].name == "_Z3foov"
    check funcSyms[1].name == "bar"
    check funcSyms[2].name == "data_var"

    let demangledSyms = elfFile.getDemangledFunctionSymbols()
    check demangledSyms.len == 3
    check demangledSyms[0].name == "foo(void)"
    check demangledSyms[1].name == "bar"
    check demangledSyms[2].name == "data_var"
