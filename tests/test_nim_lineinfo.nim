import std/[strformat, strutils, os]
import binny/elfparser

proc main() =
  # Handle both running from project root and tests directory
  let exe = if fileExists("./simple_test_program"):
    "./simple_test_program"
  elif fileExists("./tests/simple_test_program"):
    "./tests/simple_test_program"
  else:
    "simple_test_program"  # Will fail with clear error

  let elf = parseElf(exe)

  # Test with specific addresses we know are from our Nim code
  let testAddresses = [
    (0x000000000040c940'u64, "fibonacci"),
    (0x000000000040cbc0'u64, "factorial"),
    (0x000000000040ccd0'u64, "main"),
  ]

  echo "Testing DWARF line info with Nim functions:"
  echo "=" .repeat(50)
  echo ""

  for (address, name) in testAddresses:
    let (file, line) = elf.findLineInfo(address)
    echo fmt"{name:<15} @ 0x{address.toHex:>16}"
    echo fmt"  -> {file}:{line}"
    echo ""

when isMainModule:
  main()
