import ./dwarftypes

var
  gLineTable*: DwarfLineTable

proc initializeDwarfInfo*() =
  gLineTable = elf.parseDwarfLineTable()

