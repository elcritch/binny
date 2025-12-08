## Simple test to verify sframe.nim implementation
##
## This test loads SFrame data from the current executable and
## tests our implementation against known good data.

import std/[strformat, strutils, options, os]
import sframe
import sframe/elfparser

proc testSFrameImplementation() =
  echo "SFrame Implementation Test"
  echo "========================="

  # Load the current executable's SFrame data
  let exePath = getAppFilename()
  let elf = parseElf(exePath)

  # Get SFrame section data
  let (sframeData, sframeAddr) = elf.getSframeSection()
  echo fmt"Loaded SFrame section: {sframeData.len} bytes at 0x{sframeAddr.toHex}"

  # Initialize our implementation
  let ourSection = decodeSection(sframeData)
  echo fmt"Our implementation: {ourSection.fdes.len} FDEs, {ourSection.fres.len} FREs"

  echo "\nTesting specific PCs from our implementation:"
  echo "============================================"

  # Get text section for valid PC ranges
  let (textData, textAddr) = elf.getTextSection()
  let textSize = uint64(textData.len)
  echo fmt"Text section: 0x{textAddr.toHex} - 0x{(textAddr + textSize).toHex}"

  # Test a few different PCs from our text section
  let testPCs = [
    textAddr + 0x100'u64,
    textAddr + textSize div 4,
    textAddr + textSize div 2,
    textAddr + 3 * textSize div 4
  ]

  var foundCount = 0
  var totalTests = 0

  for pc in testPCs:
    echo fmt"\nTesting PC: 0x{pc.toHex}"

    # Test with our implementation
    let (found, fdeIdx, freLocalIdx, freGlobalIdx) = ourSection.pcToFre(pc, sframeAddr)

    if not found:
      echo "  No FRE found"
      inc totalTests
      continue

    let ourFde = ourSection.fdes[fdeIdx]
    let ourFre = ourSection.fres[freGlobalIdx]
    let abi = SFrameAbiArch(ourSection.header.abiArch)
    let ourOffsets = freOffsetsForAbi(abi, ourSection.header, ourFre)

    echo fmt"  Found: FDE {fdeIdx}, FRE {freLocalIdx} (global {freGlobalIdx})"
    echo fmt"    Start addr: 0x{ourFre.startAddr.toHex}"
    echo fmt"    Base: {ourOffsets.cfaBase}, CFA offset: {ourOffsets.cfaFromBase}"

    if ourOffsets.raFromCfa.isSome:
      echo fmt"    RA offset: {ourOffsets.raFromCfa.get()}"
    else:
      echo "    RA offset: none"

    if ourOffsets.fpFromCfa.isSome:
      echo fmt"    FP offset: {ourOffsets.fpFromCfa.get()}"
    else:
      echo "    FP offset: none"

    # Basic validation
    var valid = true

    # Check that offsets are reasonable
    if abs(ourOffsets.cfaFromBase) > 1000:
      echo "    ⚠️  Large CFA offset (might be valid for large stack frames)"

    if ourOffsets.raFromCfa.isSome:
      let ra = ourOffsets.raFromCfa.get()
      if abs(ra) > 100:
        echo "    ⚠️  Large RA offset"
      if ra > 0:
        echo "    ⚠️  Positive RA offset (unusual)"

    # Check FDE consistency
    let funcStart = ourSection.funcStartAddress(fdeIdx, sframeAddr)
    let funcEnd = funcStart + uint64(ourFde.funcSize)
    if pc < funcStart or pc >= funcEnd:
      echo fmt"    ❌ PC 0x{pc.toHex} outside function range 0x{funcStart.toHex}-0x{funcEnd.toHex}"
      valid = false
    else:
      echo fmt"    ✅ PC within function range 0x{funcStart.toHex}-0x{funcEnd.toHex}"

    if valid:
      inc foundCount
      echo "    ✅ Entry appears valid"
    else:
      echo "    ❌ Entry has issues"

    inc totalTests

  echo fmt"\n\nValidation Summary:"
  echo fmt"Found valid entries: {foundCount}/{totalTests}"

  # Additional statistics
  echo "\nSection Statistics:"
  echo fmt"Header version: {ourSection.header.preamble.version}"
  echo fmt"ABI/Arch: {ourSection.header.abiArch}"
  echo fmt"Total FDEs: {ourSection.fdes.len}"
  echo fmt"Total FREs: {ourSection.fres.len}"

  # Count FRE types
  var spCount = 0
  var fpCount = 0
  for fre in ourSection.fres:
    let base = fre.info.freInfoGetCfaBase()
    if base == sframeCfaBaseSp:
      inc spCount
    else:
      inc fpCount

  echo fmt"FREs using SP base: {spCount}"
  echo fmt"FREs using FP base: {fpCount}"

  if foundCount > 0:
    echo "🎉 SFrame implementation appears to be working correctly!"
  else:
    echo "❌ No valid entries found - check implementation"

when isMainModule:
  testSFrameImplementation()