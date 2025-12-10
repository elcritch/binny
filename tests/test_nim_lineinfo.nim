import std/[strformat, strutils, os, osproc, unittest]
import binny/elfparser

suite "elf line info":

  test "parse simple test program":
    # Handle both running from project root and tests directory
    let exe = "./tests/simple_test_program"
    if not fileExists(exe):
      discard execCmd("nim c -f --debugger:native " & exe)
    echo "EXE: ", exe

    let elf = parseElf(exe.absolutePath())
    let dwarfLineInfo = elf.parseDwarfLineTable()

    # Test with specific addresses we know are from our Nim code
    var testAddresses = [
      (0x000000000040ccd0'u64, "main"),
      (0x000000000040cbc0'u64, "factorial"),
      (0x000000000040c940'u64, "fibonacci"),
    ]

    let (res, code) = execCmdEx(fmt"nm {exe} | grep simple")
    let lines = res.splitLines()
    for i, line in lines:
      if line.strip() == "": continue
      let address = parseHexInt("0x" & line.split()[0])
      echo "i: ", i, " address: ", address, " line: ", line
      testAddresses[i][0] = cast[uint64](address)

    echo "Testing DWARF line info with Nim functions:"
    echo "=" .repeat(50)
    echo ""

    for (address, name) in testAddresses:
      let (file, line) = dwarfLineInfo.findLineInfo(address)
      echo fmt"{name:<15} @ 0x{address.toHex:>16}"
      echo fmt"  -> {file}:{line}"
      echo ""
      check "simple_test_program" in file
      case name:
      of "fibonacci": check line == 3
      of "factorial": check line == 10
      of "main": check line == 17

  test "parse simple test program with opts":
    # This test uses optimization flags that cause Nim to generate C code.
    # The DWARF line info points to generated C files, not original Nim source.
    # Line numbers may differ from the original Nim file.
    let exe = "./tests/simple_test_program_opts"
    if not fileExists(exe):
      discard execCmd("nim c -f " & exe)
    echo "EXE: ", exe

    let elf = parseElf(exe.absolutePath())
    let dwarfLineInfo = elf.parseDwarfLineTable()

    # Test with specific addresses we know are from our Nim code
    var testAddresses = [
      (0x000000000040ccd0'u64, "main"),
      (0x000000000040cbc0'u64, "factorial"),
      (0x000000000040c940'u64, "fibonacci"),
    ]

    let (res, code) = execCmdEx(fmt"nm {exe} | grep simple")
    let lines = res.splitLines()
    for i, line in lines:
      if line.strip() == "": continue
      let address = parseHexInt("0x" & line.split()[0])
      echo "i: ", i, " address: ", address, " line: ", line
      testAddresses[i][0] = cast[uint64](address)

    echo "Testing DWARF line info with Nim functions:"
    echo "=" .repeat(50)
    echo ""

    for (address, name) in testAddresses:
      let (file, line) = dwarfLineInfo.findLineInfo(address)
      echo fmt"{name:<15} @ 0x{address.toHex:>16}"
      echo fmt"  -> {file}:{line}"
      echo ""
      # With optimization flags, we get generated C files
      check "simple_test_program" in file
      # Line numbers are from the generated C file, so we just check they're reasonable
      check line > 0 and line < 1000

