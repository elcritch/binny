import std/[unittest, os]
import binny/elfparser
import binny/sframe
import binny/tools/dwarf2sframe
import binny/dwarf/cfi

when defined(amd64):
  suite "DWARF → SFrame converter":
    test "parseDwarfCfi parses .eh_frame and computes rows":
      let exe = getAppFilename()
      let elf = parseElf(exe)
      let pairs = parseDwarfCfi(elf, cfiEhFrame)
      check pairs.len > 0
      let pair = pairs[0]
      check pair.fde.addressRange > 0
      let rows = computeCfiRows(pair.fde, pair.cie, fpReg = 6'u64)
      check rows.len > 0
      check rows[0].address == pair.fde.initialLocation
      for i in 1 ..< rows.len:
        check rows[i].address >= rows[i - 1].address

    test "buildSFrameFromElf creates valid SFrame":
      let exe = getAppFilename()
      let elf = parseElf(exe)
      var sec = buildSFrameFromElf(elf)
      check sec.fdes.len > 0
      var sumFres = 0
      for fde in sec.fdes:
        sumFres += int(fde.funcNumFres)
      check sumFres == sec.fres.len
      check sec.fres.len >= sec.fdes.len
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
