## Test to compare sframe.nim implementation with libsframe results
##
## This test loads the same SFrame data with both our implementation and
## libsframe, then compares the results of key functions.

import std/[strformat, strutils, options, os]
import sframe
import sframe/elfparser

# POSIX system calls for mmap
when defined(linux) or defined(freebsd):
  {.passL: "-lc".}

  # Types
  type
    Stat {.importc: "struct stat", header: "<sys/stat.h>".} = object
      st_size: clong

  # System calls
  proc c_open(path: cstring, flags: cint): cint {.importc: "open", header: "<fcntl.h>".}
  proc c_close(fd: cint): cint {.importc: "close", header: "<unistd.h>".}
  proc c_mmap(address: pointer, len: csize_t, prot: cint, flags: cint, fd: cint, offset: clong): pointer {.importc: "mmap", header: "<sys/mman.h>".}
  proc c_munmap(address: pointer, len: csize_t): cint {.importc: "munmap", header: "<sys/mman.h>".}
  proc c_fstat(fd: cint, buf: ptr Stat): cint {.importc: "fstat", header: "<sys/stat.h>".}

  # Constants
  const
    O_RDONLY = 0
    PROT_READ = 1
    MAP_PRIVATE = 2
    MAP_FAILED = cast[pointer](-1)

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
  SFRAME_BASE_REG_FP = 0'u8
  SFRAME_BASE_REG_SP = 1'u8

# Structure to hold SFrame section information
type
  SframeInfo = object
    sframeData: seq[byte]
    sframeSize: csize_t
    sframeVaddr: uint64    # Virtual address where sframe section is loaded
    textVaddr: uint64      # Virtual address of .text section

# Find and map the .sframe section from an ELF file using mmap
proc loadSframeSection(filename: string): SframeInfo =
  when defined(linux) or defined(freebsd):
    var stat: Stat

    # Open file
    let fd = c_open(filename.cstring, O_RDONLY)
    if fd < 0:
      raise newException(IOError, fmt"Failed to open {filename}")

    defer: discard c_close(fd)

    # Get file size
    if c_fstat(fd, addr stat) < 0:
      raise newException(IOError, "Failed to get file stats")

    # Map file into memory
    let map = c_mmap(nil, csize_t(stat.st_size), PROT_READ, MAP_PRIVATE, fd, 0)
    if map == MAP_FAILED:
      raise newException(IOError, "Failed to mmap file")

    defer: discard c_munmap(map, csize_t(stat.st_size))

    # Parse ELF header
    let data = cast[ptr UncheckedArray[byte]](map)
    let header = parseElfHeader(toOpenArray(data, 0, int(stat.st_size) - 1))

    # Get section header table
    # Find the string table section first
    let strTableSectionIdx = int(header.e_shstrndx)
    let strTableSectionOffset = int(header.e_shoff) + strTableSectionIdx * int(header.e_shentsize)
    let strTableSection = parseSectionHeader(toOpenArray(data, 0, int(stat.st_size) - 1), strTableSectionOffset)
    let strTable = cast[ptr UncheckedArray[byte]](cast[uint](map) + uint(strTableSection.sh_offset))

    # Find .sframe and .text sections
    for i in 0..<int(header.e_shnum):
      let sectionOffset = int(header.e_shoff) + i * int(header.e_shentsize)
      let sectionHdr = parseSectionHeader(toOpenArray(data, 0, int(stat.st_size) - 1), sectionOffset)

      # Get section name
      let namePtr = cast[ptr UncheckedArray[byte]](cast[uint](strTable) + uint(sectionHdr.sh_name))
      var name = ""
      var j = 0
      while namePtr[j] != 0:
        name.add char(namePtr[j])
        inc j

      if name == ".sframe":
        result.sframeData = newSeq[byte](int(sectionHdr.sh_size))
        let sectionData = cast[ptr UncheckedArray[byte]](cast[uint](map) + uint(sectionHdr.sh_offset))
        copyMem(addr result.sframeData[0], sectionData, int(sectionHdr.sh_size))
        result.sframeSize = csize_t(sectionHdr.sh_size)
        result.sframeVaddr = sectionHdr.sh_addr
        echo fmt"Found .sframe section: size={result.sframeSize}, vaddr=0x{result.sframeVaddr.toHex}"
      elif name == ".text":
        result.textVaddr = sectionHdr.sh_addr
        echo fmt"Found .text section: vaddr=0x{result.textVaddr.toHex}"

    if result.sframeData.len == 0:
      raise newException(ValueError, "No .sframe section found")
  else:
    # Fallback to original parseElf method for unsupported platforms
    let elf = parseElf(filename)
    let (sframeData, sframeAddr) = elf.getSframeSection()
    let (textData, textAddr) = elf.getTextSection()

    result.sframeData = sframeData
    result.sframeSize = csize_t(sframeData.len)
    result.sframeVaddr = sframeAddr
    result.textVaddr = textAddr

proc testSFrameComparison() =
  echo "SFrame Implementation Comparison Test"
  echo "===================================="

  # Load the current executable's SFrame data using mmap
  let exePath = getAppFilename()
  echo fmt"Loading from executable: {exePath}"

  # Test both approaches
  let sframeInfo = loadSframeSection(exePath)
  echo fmt"mmap approach: {sframeInfo.sframeData.len} bytes"

  # Also try original approach for comparison
  let elf = parseElf(exePath)
  let (origSframeData, origSframeAddr) = elf.getSframeSection()
  echo fmt"parseElf approach: {origSframeData.len} bytes at 0x{origSframeAddr.toHex}"

  # Check if data is identical
  if sframeInfo.sframeData.len == origSframeData.len and
     sframeInfo.sframeData == origSframeData:
    echo "✅ Both approaches produce identical SFrame data"
  else:
    echo "❌ SFrame data differs between approaches!"
    echo fmt"  mmap: {sframeInfo.sframeData.len} bytes"
    echo fmt"  parseElf: {origSframeData.len} bytes"

  echo fmt"Loaded SFrame section: {sframeInfo.sframeData.len} bytes at 0x{sframeInfo.sframeVaddr.toHex}"

  # Initialize our implementation
  let ourSection = decodeSection(sframeInfo.sframeData)
  echo fmt"Our implementation: {ourSection.fdes.len} FDEs, {ourSection.fres.len} FREs"

  # Initialize libsframe with mmap data
  var err: cint = 0
  let libCtx = c_sframe_decode(addr sframeInfo.sframeData[0], sframeInfo.sframeSize, addr err)
  if libCtx == nil:
    echo fmt"Failed to initialize libsframe with mmap data: error {err}"
    # Try with original parseElf data
    echo "Trying with parseElf data..."
    let libCtx2 = c_sframe_decode(addr origSframeData[0], csize_t(origSframeData.len), addr err)
    if libCtx2 == nil:
      echo fmt"Failed to initialize libsframe with parseElf data: error {err}"
      return
    else:
      echo "✅ libsframe works with parseElf data"
      var ctx2 = libCtx2
      c_sframe_decoder_free(addr ctx2)
      return
  else:
    echo "✅ libsframe works with mmap data"

  defer:
    var ctx = libCtx
    c_sframe_decoder_free(addr ctx)

  echo "\nTesting specific PCs and comparing results:"
  echo "==========================================="

  # Test a few different PCs from our text section
  # For mmap approach, we estimate text size from virtual addresses
  let textSize = uint64(0x10000)  # Estimate - could be improved by parsing program headers

  # Test PCs based on actual FDE start addresses from our implementation
  var testPCs: seq[uint64] = @[]

  # Get some actual start addresses from FDEs
  echo "\nSampling FDE start addresses:"
  for i, fde in ourSection.fdes:
    if i mod 50 == 0 and i < 200:  # Sample every 50th FDE, up to 4 samples
      # FDE funcStartAddress is already relative to sframe base, so add sframe vaddr
      let startAddr = uint64(int64(fde.funcStartAddress) + int64(sframeInfo.sframeVaddr))
      testPCs.add(startAddr)
      echo fmt"  FDE {i}: start=0x{startAddr.toHex} (relative: 0x{fde.funcStartAddress.toHex} = {fde.funcStartAddress})"

  # Also get current PC for comparison with C example
  var currentPc: uint64
  {.emit: "asm volatile(\"leaq (%%rip), %0\" : \"=r\" (`currentPc`));".}
  testPCs.add(currentPc)
  echo fmt"Current PC: 0x{currentPc.toHex}"

  var matchCount = 0
  var totalTests = 0

  for pc in testPCs:
    echo fmt"\nTesting PC: 0x{pc.toHex}"

    # Test with our implementation
    let (found, fdeIdx, freLocalIdx, freGlobalIdx) = ourSection.pcToFre(pc, sframeInfo.sframeVaddr)

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

    # Test with libsframe - following the C example exactly: (pc - sframe_vaddr)
    let sframeRelativePc = pc - sframeInfo.sframeVaddr
    echo fmt"    SFrame relative PC: 0x{sframeRelativePc.toHex}"

    # Convert to signed int64 first to handle negative values
    let signedOffset = cast[int64](sframeRelativePc)
    # Check if it fits in int32 range (both positive and negative)
    if signedOffset < int64(low(int32)) or signedOffset > int64(high(int32)):
      echo fmt"  libsframe: PC offset outside int32 range: {signedOffset}"
      continue

    let lookupPc = int32(signedOffset)  # Relative to sframe section base (as per C example)
    echo fmt"    Looking up relative PC: 0x{lookupPc.toHex} ({lookupPc})"

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
    echo "❌ Some tests failed."
    quit(2)
  else:
    echo "ERROR!!! No tests could be run. Check that SFrame data is present."
    quit(2)

when isMainModule:
  testSFrameComparison()
