import std/[options, os, strutils, strformat]
import sframe
import sframe/mem_sim
import sframe/elfparser
export mem_sim

# Global variables to hold ELF and SFrame data
var
  gSframeSection*: SFrameSection
  gSframeSectionBase*: uint64
  gFuncSymbols*: seq[ElfSymbol]
  gInitialized*: bool = false

proc initStackframes*() =
  ## Initializes global SFrame and symbol data from the current executable.
  if gInitialized: return

  let exePath = getAppFilename()
  try:
    let elf = parseElf(exePath)

    # Load SFrame section
    let (sframeData, sframeAddr) = elf.getSframeSection()
    if sframeData.len > 0:
      gSframeSection = decodeSection(sframeData)
      gSframeSectionBase = sframeAddr

    # Load symbols
    gFuncSymbols = elf.getDemangledFunctionSymbols()
  except CatchableError as e:
    # In case of error, we can't do much. The stack trace will be less informative.
    echo "NFrame: Error during initialization: ", e.msg

  gInitialized = true


## Load stack frame data!!
initStackframes()

type U64Reader* = proc (address: uint64): uint64 {.gcsafe, raises: [], tags: [].}

# Register access utilities for AMD64
when defined(gcc) or true:
  {.emit: """
  static inline void* nframe_get_fp(void) { return __builtin_frame_address(0); }
  static inline void* nframe_get_ra(void) { return __builtin_return_address(0); }
  static inline void* nframe_get_sp(void) {
    void* sp;
#if defined(__x86_64__) || defined(__amd64__)
    __asm__ __volatile__("mov %%rsp, %0" : "=r"(sp));
#elif defined(__aarch64__)
    __asm__ __volatile__("mov %0, sp" : "=r"(sp));
#else
    sp = __builtin_frame_address(0);
#endif
    return sp;
  }
  static inline void* nframe_get_pc(void) {
    return __builtin_extract_return_addr(__builtin_return_address(0));
  }
  """.}
  proc nframe_get_fp(): pointer {.importc.}
  proc nframe_get_ra(): pointer {.importc.}
  proc nframe_get_sp(): pointer {.importc.}
  proc nframe_get_pc(): pointer {.importc.}

proc readU64Ptr*(address: uint64): uint64 =
  ## Direct memory read helper for stack walking
  cast[ptr uint64](cast[pointer](address))[]

# Follow SFrame Algorithm for efficient stack walking (for -fomit-frame-pointer scenarios)

proc isValidCodePointer*(pc: uint64): bool =
  ## Basic heuristic: code addresses should be in a reasonable range
  ## and not look like stack addresses
  if pc == 0:
    return false
  # Typical code sections are in lower memory ranges
  # Stack addresses are typically high (like 0x7f... or 0x8...)
  if pc >= 0x700000000000'u64:  # Likely stack or heap
    return false
  if pc < 0x400000'u64:  # Too low
    return false
  return true

proc walkStackWithSFrame*(sec: SFrameSection; sectionBase, startPc, startSp, startFp: uint64; readU64: U64Reader; maxFrames: int = 16): seq[uint64] {.raises: [], tags: [].} =
  ## Stack walker implementing SFrame algorithm from Appendix A
  var frames: seq[uint64] = @[startPc]

  # Current frame state (as described in Appendix A)
  var pc = startPc
  var sp = startSp
  var fp = startFp

  when defined(debug):
    try:
      echo fmt"walkStackWithSFrame: starting with pc=0x{pc.toHex}, sp=0x{sp.toHex}, fp=0x{fp.toHex}"
      echo fmt"SFrame section has {sec.fdes.len} FDEs, base=0x{sectionBase.toHex}"
    except: discard

  for frameIdx in 1 ..< maxFrames:
    # Find the FRE for the current PC (sframe_find_fre equivalent)
    let (found, fdeIdx, freLocalIdx, freGlobalIdx) = sec.pcToFre(pc, sectionBase)

    when defined(debug):
      try:
        echo fmt"Frame {frameIdx}: pc=0x{pc.toHex}, found={found}"
      except: discard

    if not found:
      # No SFrame info available - stop walking
      when defined(debug):
        try:
          echo fmt"No SFrame info for pc=0x{pc.toHex}, stopping"
        except: discard
      break

    let fde = sec.fdes[fdeIdx]
    let fre = sec.fres[freGlobalIdx]

    # Get ABI-specific offset interpretation
    let abi = SFrameAbiArch(sec.header.abiArch)
    let offsets = freOffsetsForAbi(abi, sec.header, fre)

    when defined(debug):
      try:
        echo fmt"FDE {fdeIdx}, FRE offsets: cfaFromBase={offsets.cfaFromBase}, raFromCfa={offsets.raFromCfa}, cfaBase={offsets.cfaBase}"
      except: discard

    # Get base register value (sframe_fre_base_reg_fp_p equivalent)
    let baseRegVal = if offsets.cfaBase == sframeCfaBaseFp: fp else: sp

    # Calculate CFA: CFA = BASE_REG + offset1
    let cfa = baseRegVal + uint64(cast[int64](offsets.cfaFromBase))

    # Next frame SP = CFA (as per Appendix A pseudocode)
    let nextSp = cfa

    # Get RA offset and calculate next PC
    if offsets.raFromCfa.isNone:
      # No RA information available
      when defined(debug):
        try:
          echo "No RA offset available, stopping"
        except: discard
      break

    let raOffset = offsets.raFromCfa.get()
    let raStackLoc = cfa + uint64(cast[int64](raOffset))

    # Read the return address from stack (read_value equivalent)
    let nextPc = readU64(raStackLoc)

    when defined(debug):
      try:
        echo fmt"cfa=0x{cfa.toHex}, raStackLoc=0x{raStackLoc.toHex}, nextPc=0x{nextPc.toHex}"
      except: discard

    # Validate the PC looks reasonable
    if not isValidCodePointer(nextPc):
      when defined(debug):
        try:
          echo fmt"Invalid PC 0x{nextPc.toHex}, stopping"
        except: discard
      break

    # Get FP for next frame
    let nextFp = if offsets.fpFromCfa.isSome:
      let fpOffset = offsets.fpFromCfa.get()
      let fpStackLoc = cfa + uint64(cast[int64](fpOffset))
      readU64(fpStackLoc)
    else:
      # FP not saved, continue with current value
      fp

    # Update frame state for next iteration
    pc = nextPc
    sp = nextSp
    fp = nextFp

    frames.add(pc)

  when defined(debug):
    try:
      echo fmt"walkStackWithSFrame: completed with {frames.len} frames"
    except: discard

  result = frames


# High-level stack tracing interface

proc captureStackTrace*(maxFrames: int = 64): seq[uint64] {.raises: [], gcsafe.} =
  ## High-level function to capture a complete stack trace from the current location.
  ## Returns a sequence of program counter (PC) values representing the call stack.

  {.cast(gcsafe).}:
    let fp0 = cast[uint64](nframe_get_fp())
    let sp0 = cast[uint64](nframe_get_sp())
    let ra0 = cast[uint64](nframe_get_ra())

    if gSframeSection.fdes.len == 0:
      return @[ra0]

    when defined(debug):
      try:
        echo fmt"captureStackTrace: initial fp=0x{fp0.toHex}, sp=0x{sp0.toHex}, ra=0x{ra0.toHex}"
      except: discard

    # Start with return address as first frame, then use current register state
    # to find the next frames using SFrame information
    result = walkStackWithSFrame(gSframeSection, gSframeSectionBase, ra0, sp0, fp0, readU64Ptr, maxFrames)

proc symbolizeStackTrace*(
    frames: openArray[uint64]; funcSymbols: openArray[ElfSymbol]
): seq[string] {.raises: [], gcsafe.} =
  ## Symbolize a stack trace using ELF parser for function symbols and addr2line for source locations.
  ## Uses ELF parser as primary method with addr2line fallback for enhanced source information.
  if frames.len == 0:
    return @[]


  var symbols = newSeq[string](frames.len)

  for i, pc in frames:
    var found = false
    # Find the closest function symbol
    for sym in funcSymbols:
      if pc >= sym.value and pc < (sym.value + sym.size):
        let offset = pc - sym.value
        symbols[i] = fmt"{sym.name} + 0x{offset.toHex}"
        found = true
        break

    if not found:
      symbols[i] = fmt"0x{pc.toHex} (no symbol)"


  return symbols

proc symbolizeStackTrace*(frames: openArray[uint64]): seq[string] =
  symbolizeStackTrace(frames, gFuncSymbols)

proc printStackTrace*(frames: openArray[uint64]; symbols: openArray[string] = @[]) =
  ## Print a formatted stack trace with optional symbols
  echo "Stack trace (top->bottom):"
  for i, pc in frames:
    echo "  ", ($i).align(2), ": 0x", pc.toHex.toLowerAscii()

  if symbols.len > 0:
    echo "Symbols:"
    for i, line in symbols:
      if i < frames.len:
        echo "  ", ($i).align(2), ": ", line
