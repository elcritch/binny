import std/[os, strformat, unittest, strutils, osproc]
import binny/elfparser

proc testDwarfLineInfo*(exePath: string = "") =
  echo "Testing DWARF Line Info Parser"
  echo "==============================="
  echo ""

  # Test with the current executable or specified path
  let exe = if exePath.len > 0: exePath else: getAppFilename()
  echo fmt"Testing with: {exe}"

  try:
    let elf = parseElf(exe)

    # Check if .debug_line section exists
    let debugLineIdx = elf.findSection(".debug_line")
    if debugLineIdx < 0:
      echo "No .debug_line section found in binary"
      echo "Try compiling with debug info: nim c -g <file>"
      return

    echo fmt"Found .debug_line section at index {debugLineIdx}"
    echo ""

    # Parse DWARF line table
    echo "Parsing DWARF line table..."
    let lineTable = elf.parseDwarfLineTable()

    echo fmt"DWARF Line Table Header:"
    echo fmt"  Version: {lineTable.header.version}"
    echo fmt"  Min Instruction Length: {lineTable.header.minInstructionLength}"
    echo fmt"  Max Ops Per Insn: {lineTable.header.maxOpsPerInsn}"
    echo fmt"  Default Is Stmt: {lineTable.header.defaultIsStmt}"
    echo fmt"  Line Base: {lineTable.header.lineBase}"
    echo fmt"  Line Range: {lineTable.header.lineRange}"
    echo fmt"  Opcode Base: {lineTable.header.opcodeBase}"
    echo ""

    echo fmt"Directories ({lineTable.directories.len}):"
    for i, dir in lineTable.directories:
      if i < 5:
        echo fmt"  [{i}] {dir}"
      elif i == 5:
        echo "  ... (showing first 5)"
        break
    echo ""

    echo fmt"Files ({lineTable.files.len}):"
    for i, file in lineTable.files:
      if i < 10:
        echo fmt"  [{i}] {file.name} (dir: {file.dirIndex})"
      elif i == 10:
        echo "  ... (showing first 10)"
        break
    echo ""

    echo fmt"Line entries ({lineTable.entries.len}):"
    for i, entry in lineTable.entries:
      if i < 10:
        echo fmt"  0x{entry.address.toHex:>16} -> file {entry.file:>3}, line {entry.line:>5}"
      elif i == 10:
        echo "  ... (showing first 10)"
        break
    echo ""

    # Test addr2line-like functionality
    echo "Testing addr2line functionality:"

    # Get some function symbols to test
    let funcSyms = elf.getFunctionSymbols()
    let dwarfLineInfo = elf.parseDwarfLineTable()
    if funcSyms.len > 0:
      for i in 0 ..< min(5, funcSyms.len):
        let sym = funcSyms[i]
        try:
          let (file, line) =  dwarfLineInfo.findLineInfo(sym.value)
          echo fmt"  {sym.name:<30} @ 0x{sym.value.toHex:>16} -> {file}:{line}"
        except CatchableError as e:
          echo fmt"  {sym.name:<30} @ 0x{sym.value.toHex:>16} -> Error: {e.msg}"
    else:
      echo "  No function symbols found to test"

    echo ""
    echo "DWARF line info test completed successfully!"

  except CatchableError as e:
    echo fmt"Error: {e.msg}"
    echo ""
    echo "Stack trace:"
    echo getCurrentExceptionMsg()

proc compareWithAddr2line*(exePath: string = "") =
  echo ""
  echo "Comparing with addr2line"
  echo "========================"

  let exe = if exePath.len > 0: exePath else: getAppFilename()

  # Try to find addr2line
  var addr2line = "addr2line"
  if fileExists("/usr/local/bin/x86_64-unknown-freebsd15.0-addr2line"):
    addr2line = "/usr/local/bin/x86_64-unknown-freebsd15.0-addr2line"
  elif not findExe(addr2line).len > 0:
    echo "addr2line not found, skipping comparison"
    return

  try:
    let elf = parseElf(exe)
    let dwarfLineInfo = elf.parseDwarfLineTable()

    # Check if .debug_line exists
    let debugLineIdx = elf.findSection(".debug_line")
    if debugLineIdx < 0:
      echo "No .debug_line section, skipping comparison"
      return

    # Get some function symbols
    let funcSyms = elf.getFunctionSymbols()
    if funcSyms.len == 0:
      echo "No function symbols found"
      return

    echo fmt"Comparing first {min(5, funcSyms.len)} function addresses:"
    echo ""

    for i in 0 ..< min(5, funcSyms.len):
      let sym = funcSyms[i]
      let addrHex = fmt"0x{sym.value.toHex}"

      # Get our result
      var ourResult = "??"
      try:
        let (file, line) = dwarfLineInfo.findLineInfo(sym.value)
        ourResult = fmt"{file}:{line}"
      except:
        ourResult = "Error"

      # Get addr2line result
      let cmd = fmt"{addr2line} -e {exe} {addrHex}"
      let addr2lineResult = execProcess(cmd).strip()

      echo fmt"Address: {addrHex} ({sym.name})"
      echo fmt"  Our parser:  {ourResult}"
      echo fmt"  addr2line:   {addr2lineResult}"

      if ourResult == addr2lineResult:
        echo "  ✓ Match!"
      else:
        echo "  ✗ Mismatch"
      echo ""

  except CatchableError as e:
    echo fmt"Error in comparison: {e.msg}"

when isMainModule:
  var exePath = ""

  # Simple argument parsing
  let params = commandLineParams()
  if params.len > 0:
    exePath = params[0]
    echo fmt"Command line argument: {exePath}"
    echo ""

  testDwarfLineInfo(exePath)
  compareWithAddr2line(exePath)
