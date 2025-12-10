import std/[unittest, strformat, strutils]
import binny/sframe
import binny/elfparser
import binny/sframe/stackwalk
import binny/dwarf

when defined(amd64):
  suite "AMD64 walker helpers":
    test "symbolizeStackTrace maps PCs to demangled names + offsets":
      # Stub two function symbols with known ranges
      let syms = @[
        ElfSymbol(name: "foo", value: 0x400000'u64, size: 0x50'u64),
        ElfSymbol(name: "bar", value: 0x400050'u64, size: 0x30'u64),
      ]
      let frames = [0x400010'u64, 0x400060'u64, 0x500000'u64] # last has no symbol
      let lines = symbolizeStackTraceImpl(frames, syms, DwarfLineTable())
      check lines.len == 3
      check lines[0] == "foo + 0x0000000000000010"
      check lines[1] == "bar + 0x0000000000000010"
      check lines[2].startsWith("0x0000000000500000")

    test "printStackTrace handles basic formatting":
      let frames = [0x400000'u64, 0x400010'u64]
      # Just ensure it doesn't raise and prints in expected format
      printStackTrace(frames)
