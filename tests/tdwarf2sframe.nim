import std/[unittest, strformat, os]
import binny/elfparser
import binny/sframe
import binny/tools/dwarf2sframe

when defined(amd64):
  suite "DWARF → SFrame converter":
    test "buildSFrameFromElf creates valid SFrame":
      let exe = getAppFilename()
      let elf = parseElf(exe)
      var sec = buildSFrameFromElf(elf)
      check sec.fdes.len > 0
      check sec.fres.len == sec.fdes.len
      check sec.header.preamble.version == SFRAME_VERSION_2
      check SFrameAbiArch(sec.header.abiArch) == sframeAbiAmd64Little

      # Encode and decode roundtrip
      let bytes = encodeSection(sec)
      let parsed = decodeSection(bytes)
      let errs = validateSection(parsed)
      if errs.len > 0:
        for e in errs: echo e
      check errs.len == 0
else:
  when isMainModule:
    echo "Skipping tdwarf2sframe on non-amd64 architecture"

