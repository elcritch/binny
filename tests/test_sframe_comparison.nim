## Test to compare sframe.nim implementation with libsframe results
##
## This test loads the same SFrame data with both our implementation and
## libsframe, then compares the results of key functions.

import std/[strformat, strutils, options, os]
import sframe
import sframe/elfparser

# Simple libsframe wrapper - keep minimal for testing
{.emit: """
#include "sframe-api.h"

// Wrapper functions to avoid conflicts
static sframe_decoder_ctx* nim_sframe_decode(const void* cf_buf, size_t cf_size, int* errp) {
    return sframe_decode((const char*)cf_buf, cf_size, errp);
}

static void nim_sframe_decoder_free(sframe_decoder_ctx** dctx) {
    sframe_decoder_free(dctx);
}

static int nim_sframe_find_fre(sframe_decoder_ctx* ctx, int32_t pc, sframe_frame_row_entry* fre) {
    return sframe_find_fre(ctx, pc, fre);
}

static uint8_t nim_sframe_fre_get_base_reg_id(sframe_frame_row_entry* fre, int* errp) {
    return sframe_fre_get_base_reg_id(fre, errp);
}

static int32_t nim_sframe_fre_get_cfa_offset(sframe_decoder_ctx* dctx, sframe_frame_row_entry* fre, int* errp) {
    return sframe_fre_get_cfa_offset(dctx, fre, errp);
}

static int32_t nim_sframe_fre_get_ra_offset(sframe_decoder_ctx* dctx, sframe_frame_row_entry* fre, int* errp) {
    return sframe_fre_get_ra_offset(dctx, fre, errp);
}

static int32_t nim_sframe_fre_get_fp_offset(sframe_decoder_ctx* dctx, sframe_frame_row_entry* fre, int* errp) {
    return sframe_fre_get_fp_offset(dctx, fre, errp);
}
""".}

# Use the actual opaque types from libsframe
type
  sframe_decoder_ctx {.importc, incompletestruct.} = object
  sframe_frame_row_entry {.importc, incompletestruct.} = object

# libsframe wrapper function calls
proc nim_sframe_decode(cf_buf: ptr UncheckedArray[byte], cf_size: csize_t, errp: ptr cint): ptr sframe_decoder_ctx {.importc.}
proc nim_sframe_decoder_free(dctx: ptr (ptr sframe_decoder_ctx)) {.importc.}
proc nim_sframe_find_fre(ctx: ptr sframe_decoder_ctx, pc: int32, fre: ptr sframe_frame_row_entry): cint {.importc.}

proc nim_sframe_fre_get_base_reg_id(fre: ptr sframe_frame_row_entry, errp: ptr cint): uint8 {.importc.}
proc nim_sframe_fre_get_cfa_offset(dctx: ptr sframe_decoder_ctx, fre: ptr sframe_frame_row_entry, errp: ptr cint): int32 {.importc.}
proc nim_sframe_fre_get_ra_offset(dctx: ptr sframe_decoder_ctx, fre: ptr sframe_frame_row_entry, errp: ptr cint): int32 {.importc.}
proc nim_sframe_fre_get_fp_offset(dctx: ptr sframe_decoder_ctx, fre: ptr sframe_frame_row_entry, errp: ptr cint): int32 {.importc.}

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
  let libCtx = nim_sframe_decode(cast[ptr UncheckedArray[byte]](addr sframeData[0]), csize_t(sframeData.len), addr err)
  if libCtx == nil:
    echo fmt"Failed to initialize libsframe: error {err}"
    return

  defer:
    var ctx = libCtx
    nim_sframe_decoder_free(addr ctx)

  echo "\nTesting specific PCs and comparing results:"
  echo "==========================================="

  # Test a few different PCs from our text section
  let (textData, textAddr) = elf.getTextSection()
  let textSize = uint64(textData.len)

  # Test PCs at various offsets in the text section
  let testPCs = [
    textAddr + 0x100'u64,    # Near start
    textAddr + textSize div 4,   # Quarter way
    textAddr + textSize div 2,   # Halfway
    textAddr + 3 * textSize div 4, # Three quarters
    textAddr + textSize - 0x100'u64  # Near end
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
    echo fmt"    RA offset: {ourOffsets.raFromCfa.get(0)}"
    echo fmt"    FP offset: {ourOffsets.fpFromCfa.get(0)}"

    # Test with libsframe
    let lookupPc = int32(pc - sframeAddr)  # Relative to section base
    var libFre: sframe_frame_row_entry
    let libErr = nim_sframe_find_fre(libCtx, lookupPc, addr libFre)

    if libErr != 0:
      echo fmt"  libsframe: No FRE found (error {libErr})"
      continue

    # Get libsframe results
    var getErr: cint = 0
    let libBaseReg = nim_sframe_fre_get_base_reg_id(addr libFre, addr getErr)
    let libCfaOffset = nim_sframe_fre_get_cfa_offset(libCtx, addr libFre, addr getErr)
    let libRaOffset = nim_sframe_fre_get_ra_offset(libCtx, addr libFre, addr getErr)
    let libFpOffset = nim_sframe_fre_get_fp_offset(libCtx, addr libFre, addr getErr)

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
      echo fmt"    ❌ Base register mismatch: our={ourOffsets.cfaBase}, lib={expectedBase}"
      matches = false
    else:
      echo "    ✅ Base register matches"

    # Compare CFA offset
    if ourOffsets.cfaFromBase != libCfaOffset:
      echo fmt"    ❌ CFA offset mismatch: our={ourOffsets.cfaFromBase}, lib={libCfaOffset}"
      matches = false
    else:
      echo "    ✅ CFA offset matches"

    # Compare RA offset
    if ourOffsets.raFromCfa.get(0) != libRaOffset:
      echo fmt"    ❌ RA offset mismatch: our={ourOffsets.raFromCfa.get(0)}, lib={libRaOffset}"
      matches = false
    else:
      echo "    ✅ RA offset matches"

    # Compare FP offset (if both have it)
    if ourOffsets.fpFromCfa.isSome and libFpOffset != 0:
      if ourOffsets.fpFromCfa.get() != libFpOffset:
        echo fmt"    ❌ FP offset mismatch: our={ourOffsets.fpFromCfa.get()}, lib={libFpOffset}"
        matches = false
      else:
        echo "    ✅ FP offset matches"
    elif ourOffsets.fpFromCfa.isNone and libFpOffset == 0:
      echo "    ✅ FP offset matches (both have none)"
    else:
      echo fmt"    ⚠️ FP offset availability differs: our={ourOffsets.fpFromCfa.isSome}, lib={libFpOffset != 0}"

    if matches:
      echo "    🎉 All offsets match!"
      inc matchCount
    else:
      echo "    ❌ Some offsets don't match"

    inc totalTests

  echo fmt"\n\nSummary: {matchCount}/{totalTests} test cases matched completely"
  if matchCount == totalTests:
    echo "🎉 All tests passed! Our implementation matches libsframe."
  else:
    echo "❌ Some tests failed. There may be differences in implementation."

when isMainModule:
  testSFrameComparison()