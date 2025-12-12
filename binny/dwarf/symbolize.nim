import ../elfparser
import ./dwarftypes

var gLineTable*: DwarfLineTable

proc initializeDwarfInfo*(elf: ElfFile) =
  gLineTable = elf.parseDwarfLineTable()
