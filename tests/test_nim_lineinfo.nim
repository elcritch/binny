import std/[strformat, strutils, os, osproc, unittest]
import binny/elfparser

suite "elf line info":

  test "parse simple test program":
    # Handle both running from project root and tests directory
    let exe = "./tests/simple_test_program"
    if not fileExists(exe):
      discard execCmd("nim c --debugger:native -f tests/simple_test_program.nim")
    echo "EXE: ", exe

    let elf = parseElf(exe.absolutePath())
    let dwarfLineInfo = elf.parseDwarfLineTable()

    # Test with specific addresses we know are from our Nim code
    var testAddresses = [
      (0x000000000040ccd0'u64, "main"),
      (0x000000000040cbc0'u64, "factorial"),
      (0x000000000040c940'u64, "fibonacci"),
    ]

    let (res, code) = execCmdEx("nm ./tests/simple_test_program | grep simple")
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

