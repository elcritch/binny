import std/[options, os, strutils, strformat]
import sframe
import sframe/mem_sim
import sframe/elfparser
export mem_sim

# Global variables to hold ELF and SFrame data
var
  gSframeSection*: SFrameSection
  gSframeSectionBase*: uint64
  gTextSectionBase*: uint64
  gTextSectionSize*: uint64
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

    # Load text section
    let (textData, textAddr) = elf.getTextSection()
    gTextSectionBase = textAddr
    gTextSectionSize = uint64(textData.len)

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

proc walkStackWithSFrame*(sec: SFrameSection; sectionBase, textVaddr, textSize, startPc, startSp, startFp: uint64; readU64: U64Reader; maxFrames: int = 16): seq[uint64] {.raises: [], tags: [].} =
  ## Stack walker implementing SFrame algorithm similar to sframe_stack_example.c
  ## This follows the algorithm from lines 179-274 of sframe_stack_example.c
  var frames: seq[uint64] = @[]

  # Current frame state - start with current PC, SP, and FP
  var pc = startPc
  var sp = startSp
  var fp = startFp
  var frameCount = 0

  when defined(debug):
    try:
      echo fmt"walkStackWithSFrame: Starting from PC=0x{pc.toHex}, SP=0x{sp.toHex}"
      echo fmt"  sectionBase=0x{sectionBase.toHex}, textVaddr=0x{textVaddr.toHex}, textSize=0x{textSize.toHex}"
    except: discard

  # Walk the stack using SFrame information
  while frameCount < maxFrames:
    # Add current PC to frames
    frames.add(pc)

    when defined(debug):
      try:
        echo fmt"Frame {frameCount}: PC=0x{pc.toHex} SP=0x{sp.toHex}"
      except: discard

    # Check if PC is in our text section (similar to lines 208-260 in C example)
    if pc < textVaddr or pc >= (textVaddr + textSize):
      when defined(debug):
        try:
          echo fmt"  PC outside text section (0x{textVaddr.toHex} - 0x{(textVaddr + textSize).toHex})"
        except: discard
      break

    # Find the FRE for this PC using our Nim library
    # This replaces sframe_find_fre from the C example
    let lookup = sec.pcToFre(pc, sectionBase)
    if not lookup.found:
      when defined(debug):
        try:
          echo fmt"  No FRE found for PC"
        except: discard
      break

    # Extract offsets using our ABI-specific helper
    let fdeIdx = lookup.fdeIdx
    let freGlobalIdx = lookup.freGlobalIdx
    let fre = sec.fres[freGlobalIdx]
    let abi = SFrameAbiArch(sec.header.abiArch)

    let offsets = freOffsetsForAbi(abi, sec.header, fre)

    when defined(debug):
      try:
        echo fmt"  Found FRE: fdeIdx={fdeIdx}, freIdx={freGlobalIdx}, startAddr=0x{fre.startAddr.toHex}"
        echo fmt"  CFA base: {offsets.cfaBase}, offset: {offsets.cfaFromBase}"
        if offsets.raFromCfa.isSome:
          echo fmt"  RA offset: {offsets.raFromCfa.get()}"
      except: discard

    # Check if we have RA offset
    if offsets.raFromCfa.isNone:
      when defined(debug):
        try:
          echo fmt"  No RA offset available"
        except: discard
      break

    # Calculate CFA (Canonical Frame Address) based on the base register
    var cfa: uint64
    if offsets.cfaBase == sframeCfaBaseSp:
      # SP-based: CFA = SP + cfa_offset (matching line 225 in C example)
      cfa = sp + uint64(offsets.cfaFromBase)
    elif offsets.cfaBase == sframeCfaBaseFp:
      # FP-based: CFA = FP + cfa_offset
      cfa = fp + uint64(offsets.cfaFromBase)
    else:
      when defined(debug):
        try:
          echo fmt"  Unknown CFA base register"
        except: discard
      break

    # Calculate return address location: CFA + ra_offset
    # This matches line 226 in the C example
    # Note: offsets are signed, so we need to handle them properly
    let raOffset = offsets.raFromCfa.get()
    let raAddr = if raOffset >= 0:
                   cfa + uint64(raOffset)
                 else:
                   cfa - uint64(-raOffset)

    when defined(debug):
      try:
        echo fmt"  CFA=0x{cfa.toHex}, RA addr=0x{raAddr.toHex}"
      except: discard

    # Validate RA address is within reasonable stack bounds (lines 242-249 in C example)
    # For FP-based unwinding, we need a wider range check
    let stackCheckLower = if offsets.cfaBase == sframeCfaBaseFp: sp else: sp
    let stackCheckUpper = if offsets.cfaBase == sframeCfaBaseFp: sp + 4096'u64 else: sp + 1024'u64
    if raAddr <= stackCheckLower or raAddr >= stackCheckUpper:
      when defined(debug):
        try:
          echo fmt"  Invalid RA address (not in stack range 0x{stackCheckLower.toHex} - 0x{stackCheckUpper.toHex})"
        except: discard
      break

    # Read the return address from the stack
    try:
      let nextPc = readU64(raAddr)

      when defined(debug):
        try:
          echo fmt"  Next PC=0x{nextPc.toHex}"
        except: discard

      # Validate the next PC
      if nextPc == 0 or not isValidCodePointer(nextPc):
        when defined(debug):
          try:
            echo fmt"  Invalid next PC"
          except: discard
        break

      # Update frame state for next iteration
      # For FP-based unwinding, read the previous FP from the stack
      var nextFp = fp
      if offsets.cfaBase == sframeCfaBaseFp:
        # In standard calling conventions, the saved FP is typically at FP+0 or from the FP offset
        if offsets.fpFromCfa.isSome:
          let fpOffset = offsets.fpFromCfa.get()
          let fpAddr = if fpOffset >= 0:
                         cfa + uint64(fpOffset)
                       else:
                         cfa - uint64(-fpOffset)
          try:
            nextFp = readU64(fpAddr)
            when defined(debug):
              try:
                echo fmt"  Next FP=0x{nextFp.toHex} (from CFA+{fpOffset}, addr=0x{fpAddr.toHex})"
              except: discard
          except:
            when defined(debug):
              try:
                echo fmt"  Failed to read FP at 0x{fpAddr.toHex}, using current FP"
              except: discard
        else:
          # Standard x86-64 convention: saved FP is at current FP
          try:
            nextFp = readU64(fp)
            when defined(debug):
              try:
                echo fmt"  Next FP=0x{nextFp.toHex} (from *FP)"
              except: discard
          except:
            when defined(debug):
              try:
                echo fmt"  Failed to read FP at 0x{fp.toHex}"
              except: discard

      # Update frame state (matching line 244 in C example)
      pc = nextPc
      sp = cfa
      fp = nextFp
      frameCount += 1

    except:
      # If we can't read memory, stop unwinding
      when defined(debug):
        try:
          echo fmt"  Failed to read memory at 0x{raAddr.toHex}"
        except: discard
      break

  when defined(debug):
    try:
      echo fmt"walkStackWithSFrame: Found {frames.len} frames"
    except: discard

  return frames

# High-level stack tracing interface

proc captureStackTrace*(maxFrames: int = 64): seq[uint64] {.raises: [], gcsafe.} =
  ## High-level function to capture a complete stack trace from the current location.
  ## Returns a sequence of program counter (PC) values representing the call stack.

  {.cast(gcsafe).}:
    let sp0 = cast[uint64](nframe_get_sp())
    let fp0 = cast[uint64](nframe_get_fp())
    let pc0 = cast[uint64](nframe_get_pc())

    if gSframeSection.fdes.len == 0:
      return @[pc0]

    when defined(debug):
      try:
        echo fmt"captureStackTrace: initial pc=0x{pc0.toHex}, sp=0x{sp0.toHex}, fp=0x{fp0.toHex}"
        echo fmt"SFrame section has {gSframeSection.fdes.len} FDEs, base=0x{gSframeSectionBase.toHex}, text=0x{gTextSectionBase.toHex}"
        # Check if our PC is in the deep function range
        if pc0 >= 0x41c400'u64 and pc0 <= 0x41c800'u64:
          echo fmt"PC is in deep function range!"
      except: discard

    # Start with current PC, SP, and FP, then use SFrame information to unwind
    result = walkStackWithSFrame(gSframeSection, gSframeSectionBase, gTextSectionBase, gTextSectionSize, pc0, sp0, fp0, readU64Ptr, maxFrames)

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
