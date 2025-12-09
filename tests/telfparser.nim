import std/[os, strformat, unittest, strutils, osproc, parseopt, cmdline]
import binny/elfparser
import binny/sframe

proc testElfParser*(exePath: string = "") =
  echo "Testing ELF Parser"
  echo "=================="

  # Test with the current executable or specified path
  let exe = if exePath.len > 0: exePath else: getAppFilename()
  echo fmt"Testing with: {exe}"

  try:
    let elf = parseElf(exe)

    echo fmt"ELF header parsed successfully:"
    echo fmt"  Type: {elf.header.e_type} (ET_EXEC=2, ET_DYN=3)"
    echo fmt"  Machine: {elf.header.e_machine}"
    echo fmt"  Entry: 0x{elf.header.e_entry.toHex}"
    echo fmt"  Sections: {elf.header.e_shnum}"
    echo fmt"  Section header string table index: {elf.header.e_shstrndx}"
    echo ""

    echo "Sections found:"
    let sections = elf.listSections()
    for i, name in sections:
      let section = elf.sections[i]
      echo fmt"  [{i:2}] {name:<20} type={section.sectionType:2} addr=0x{section.address.toHex:>16} size={section.size:>8}"

    echo ""

    # Test SFrame section extraction
    echo "Testing SFrame section extraction:"
    try:
      let (sframeData, sframeAddr) = elf.getSframeSection()
      echo fmt"  Found .sframe section: {sframeData.len} bytes at 0x{sframeAddr.toHex}"

      # Try to parse the SFrame data
      try:
        let sframeSection = decodeSection(sframeData)
        echo fmt"  SFrame section parsed successfully:"
        echo fmt"    Magic: 0x{sframeSection.header.preamble.magic.toHex}"
        echo fmt"    Version: {sframeSection.header.preamble.version}"
        echo fmt"    FDEs: {sframeSection.header.numFdes}"
        echo fmt"    FREs: {sframeSection.header.numFres}"
      except CatchableError as e:
        echo fmt"  Error parsing SFrame data: {e.msg}"
    except CatchableError as e:
      echo fmt"  No .sframe section found or error: {e.msg}"

    echo ""

    # Test text section extraction
    echo "Testing text section extraction:"
    try:
      let (textData, textAddr) = elf.getTextSection()
      echo fmt"  Found .text section: {textData.len} bytes at 0x{textAddr.toHex}"
    except CatchableError as e:
      echo fmt"  Error getting .text section: {e.msg}"

    echo ""

    # Test function symbol extraction
    echo "Testing function symbol extraction:"
    let funcSyms = elf.getFunctionSymbols()
    echo fmt"  Found {funcSyms.len} function symbols:"
    for i, sym in funcSyms:
      if i < 10:  # Show only first 10
        echo fmt"    {sym.name:<30} addr=0x{sym.value.toHex:>16} size={sym.size:>6}"
      elif i == 10:
        echo "    ... (showing first 10)"
        break

  except CatchableError as e:
    echo fmt"Error parsing ELF file: {e.msg}"

proc compareWithObjdump*() =
  echo ""
  echo "Comparing with objdump"
  echo "====================="

  let exe = getAppFilename()
  let objdump = "/usr/local/bin/x86_64-unknown-freebsd15.0-objdump"

  if not fileExists(objdump):
    echo "objdump not found, skipping comparison"
    return

  try:
    # Parse with our ELF parser
    let elf = parseElf(exe)

    echo "Section comparison:"
    echo "Our parser vs objdump -h:"

    # Get objdump output
    let objdumpOutput = execProcess(objdump & " -h " & exe)

    echo "objdump sections:"
    for line in objdumpOutput.splitLines():
      if line.contains(".sframe") or line.contains(".text") or line.contains(".strtab"):
        echo fmt"  objdump: {line.strip()}"

    echo ""
    echo "Our parser sections:"
    for section in elf.sections:
      if section.name in [".sframe", ".text", ".strtab"]:
        echo fmt"  ours:    {section.name:<20} addr=0x{section.address.toHex:>16} size=0x{section.size.toHex:>8}"

  except CatchableError as e:
    echo fmt"Error in comparison: {e.msg}"

when isMainModule:
  var exePath = ""

  # Simple argument parsing - take the first argument as the exe path
  let params = commandLineParams()
  if params.len > 0:
    exePath = params[0]
    echo fmt"Command line argument: {exePath}"

  testElfParser(exePath)
  compareWithObjdump()
