## Test to compare sframe.nim implementation with libsframe results
##
## This test loads the same SFrame data with both our implementation and
## libsframe, then compares the results of key functions.

import std/[strformat, strutils, options, os]
import sframe
import sframe/elfparser

# Use direct library linking approach
{.passL: "-lsframe".}

# Use direct C function calls with proper typing
proc c_sframe_decode(buf: pointer, size: csize_t, errp: ptr cint): pointer {.
  importc: "sframe_decode", header: "<sframe-api.h>".}

proc c_sframe_decoder_free(dctx: ptr pointer) {.
  importc: "sframe_decoder_free", header: "<sframe-api.h>".}

proc c_sframe_find_fre(dctx: pointer, pc: int32, fre: pointer): cint {.
  importc: "sframe_find_fre", header: "<sframe-api.h>".}

proc c_sframe_fre_get_base_reg_id(fre: pointer, errp: ptr cint): uint8 {.
  importc: "sframe_fre_get_base_reg_id", header: "<sframe-api.h>".}

proc c_sframe_fre_get_cfa_offset(dctx: pointer, fre: pointer, errp: ptr cint): int32 {.
  importc: "sframe_fre_get_cfa_offset", header: "<sframe-api.h>".}

proc c_sframe_fre_get_ra_offset(dctx: pointer, fre: pointer, errp: ptr cint): int32 {.
  importc: "sframe_fre_get_ra_offset", header: "<sframe-api.h>".}

proc c_sframe_fre_get_fp_offset(dctx: pointer, fre: pointer, errp: ptr cint): int32 {.
  importc: "sframe_fre_get_fp_offset", header: "<sframe-api.h>".}

# Constants from sframe-api.h
const
  SFRAME_BASE_REG_SP = 0'u8
  SFRAME_BASE_REG_FP = 1'u8

proc testSFrameComparison() =
  echo "SFrame Implementation Comparison Test"
  echo "===================================="

  # Load the current executable's SFrame data
  let exePath = getAppFilename()
  let elf = parseElf(exePath)

  # Get SFrame section data
  let (sframeData, sframeAddr) = elf.getSframeSection()
  echo fmt"Loaded SFrame section: {sframeData.len} bytes at 0x{sframeAddr.toHex}"

  # Initialize our implementation
  let ourSection = decodeSection(sframeData)
  echo fmt"Our implementation: {ourSection.fdes.len} FDEs, {ourSection.fres.len} FREs"

  # Initialize libsframe
  var err: cint = 0
  let libCtx = c_sframe_decode(addr sframeData[0], csize_t(sframeData.len), addr err)
  if libCtx == nil:
    echo fmt"Failed to initialize libsframe: error {err}"
    return

  defer:
    var ctx = libCtx
    c_sframe_decoder_free(addr ctx)

  echo "\nTesting specific PCs and comparing results:"
  echo "==========================================="

  # Test a few different PCs from our text section
  let (textData, textAddr) = elf.getTextSection()
  let textSize = uint64(textData.len)

  # Test PCs at various offsets in the text section
  let testPCs = [
    textAddr + textSize div 4,   # Quarter way
    textAddr + textSize div 2,   # Halfway
    textAddr + 3 * textSize div 4, # Three quarters
  ]

  var matchCount = 0
  var totalTests = 0

  for pc in testPCs:
    echo fmt"\nTesting PC: 0x{pc.toHex}"

    # Test with our implementation
    let (found, fdeIdx, freLocalIdx, freGlobalIdx) = ourSection.pcToFre(pc, sframeAddr)

    if not found:
      echo "  Our impl: No FRE found"
      continue

    let ourFde = ourSection.fdes[fdeIdx]
    let ourFre = ourSection.fres[freGlobalIdx]
    let abi = SFrameAbiArch(ourSection.header.abiArch)
    let ourOffsets = freOffsetsForAbi(abi, ourSection.header, ourFre)

    echo fmt"  Our impl: FDE {fdeIdx}, FRE {freLocalIdx}"
    echo fmt"    Base: {ourOffsets.cfaBase}, CFA offset: {ourOffsets.cfaFromBase}"
    if ourOffsets.raFromCfa.isSome:
      echo fmt"    RA offset: {ourOffsets.raFromCfa.get()}"
    else:
      echo "    RA offset: none"
    if ourOffsets.fpFromCfa.isSome:
      echo fmt"    FP offset: {ourOffsets.fpFromCfa.get()}"
    else:
      echo "    FP offset: none"

    # Test with libsframe - PC should be relative to text section start
    # Looking at the C example, it uses (pc - sframe_info->sframe_vaddr)
    # But in the context, that pc is already relative to text base in their usage
    # Let's try using our PC relative to text base
    let textRelativePc = pc - textAddr
    echo fmt"    Text relative PC: 0x{textRelativePc.toHex}"

    # Check if offset fits in int32 range
    if textRelativePc > uint64(high(int32)):
      echo fmt"  libsframe: PC offset too large for int32: {textRelativePc}"
      continue

    let lookupPc = int32(textRelativePc)  # Relative to text section base
    echo fmt"    Looking up relative PC: 0x{lookupPc.toHex}"

    try:
      var libFre: array[1024, byte]  # Allocate space for FRE
      let libErr = c_sframe_find_fre(libCtx, lookupPc, addr libFre[0])

      if libErr != 0:
        echo fmt"  libsframe: No FRE found (error {libErr})"
        continue

      # Get libsframe results
      var getErr: cint = 0
      let libBaseReg = c_sframe_fre_get_base_reg_id(addr libFre[0], addr getErr)
      if getErr != 0:
        echo fmt"  libsframe: Error getting base reg id (error {getErr})"
        continue

      let libCfaOffset = c_sframe_fre_get_cfa_offset(libCtx, addr libFre[0], addr getErr)
      if getErr != 0:
        echo fmt"  libsframe: Error getting CFA offset (error {getErr})"
        continue

      let libRaOffset = c_sframe_fre_get_ra_offset(libCtx, addr libFre[0], addr getErr)
      if getErr != 0:
        echo fmt"  libsframe: Error getting RA offset (error {getErr})"
        continue

      let libFpOffset = c_sframe_fre_get_fp_offset(libCtx, addr libFre[0], addr getErr)
      # FP offset errors are acceptable

      let libBaseRegName = if libBaseReg == SFRAME_BASE_REG_SP: "sframeCfaBaseSp" else: "sframeCfaBaseFp"

      echo fmt"  libsframe: Found FRE"
      echo fmt"    Base: {libBaseRegName}, CFA offset: {libCfaOffset}"
      echo fmt"    RA offset: {libRaOffset}"
      echo fmt"    FP offset: {libFpOffset}"

      # Compare results
      var matches = true

      # Compare base register
      let expectedBase = if libBaseReg == SFRAME_BASE_REG_SP: sframeCfaBaseSp else: sframeCfaBaseFp
      if ourOffsets.cfaBase != expectedBase:
        echo fmt"      ❌ Base register mismatch: our={ourOffsets.cfaBase}, lib={expectedBase}"
        matches = false
      else:
        echo "      ✅ Base register matches"

      # Compare CFA offset
      if ourOffsets.cfaFromBase != libCfaOffset:
        echo fmt"      ❌ CFA offset mismatch: our={ourOffsets.cfaFromBase}, lib={libCfaOffset}"
        matches = false
      else:
        echo "      ✅ CFA offset matches"

      # Compare RA offset
      if ourOffsets.raFromCfa.isSome:
        if ourOffsets.raFromCfa.get() != libRaOffset:
          echo fmt"      ❌ RA offset mismatch: our={ourOffsets.raFromCfa.get()}, lib={libRaOffset}"
          matches = false
        else:
          echo "      ✅ RA offset matches"
      else:
        echo "      ⚠️ Our impl has no RA offset"

      # Compare FP offset (if both have it)
      if ourOffsets.fpFromCfa.isSome and libFpOffset != 0:
        if ourOffsets.fpFromCfa.get() != libFpOffset:
          echo fmt"      ❌ FP offset mismatch: our={ourOffsets.fpFromCfa.get()}, lib={libFpOffset}"
          matches = false
        else:
          echo "      ✅ FP offset matches"
      elif ourOffsets.fpFromCfa.isNone and libFpOffset == 0:
        echo "      ✅ FP offset matches (both have none)"
      else:
        echo fmt"      ⚠️ FP offset availability differs: our={ourOffsets.fpFromCfa.isSome}, lib={libFpOffset != 0}"

      if matches:
        echo "      🎉 All offsets match!"
        inc matchCount
      else:
        echo "      ❌ Some offsets don't match"

      inc totalTests

    except CatchableError as e:
      echo fmt"  libsframe: Exception occurred: {e.msg}"
      continue

  echo fmt"\n\nSummary: {matchCount}/{totalTests} test cases matched completely"
  if matchCount == totalTests and totalTests > 0:
    echo "🎉 All tests passed! Our implementation matches libsframe."
  elif totalTests > 0:
    echo "❌ Some tests failed. There may be differences in implementation."
  else:
    echo "⚠️ No tests could be run. Check that SFrame data is present."

when isMainModule:
  testSFrameComparison()