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
  ## Stack walker implementing SFrame algorithm matching sframe_stack_example.nim
  ## This follows the algorithm from sframe_stack_example.nim:219-305
  var frames: seq[uint64] = @[]

  # Current frame state - start with current PC and SP
  var pc = startPc
  var sp = startSp
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

    # Check if PC is in our text section (matching sframe_stack_example.nim:244)
    if pc < textVaddr or pc >= (textVaddr + textSize):
      when defined(debug):
        try:
          echo fmt"  PC outside text section (0x{textVaddr.toHex} - 0x{(textVaddr + textSize).toHex})"
        except: discard
      break

    # Find the FRE for this PC using our Nim library
    # This replaces sframe_find_fre from the C example (sframe_stack_example.nim:245-249)
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

    # Only handle SP-based unwinding (matching sframe_stack_example.nim:268-287)
    # The libsframe example skips FP-based frames because Nim doesn't maintain proper frame pointers
    if offsets.cfaBase != sframeCfaBaseSp:
      when defined(debug):
        try:
          echo fmt"  FP-based frame - skipping (Nim doesn't maintain proper frame pointers)"
        except: discard
      break

    # SP-based: CFA = SP + cfa_offset (matching sframe_stack_example.nim:270)
    # Note: cfaFromBase is signed, but typically positive for SP-based unwinding
    let cfaOffset = offsets.cfaFromBase
    let cfa = if cfaOffset >= 0:
                sp + uint64(cfaOffset)
              else:
                sp - uint64(-cfaOffset)

    # Calculate return address location: CFA + ra_offset (sframe_stack_example.nim:271)
    # Note: raOffset is signed and can be negative
    let raOffset = offsets.raFromCfa.get()
    let raAddr = if raOffset >= 0:
                   cfa + uint64(raOffset)
                 else:
                   cfa - uint64(-raOffset)

    when defined(debug):
      try:
        echo fmt"  cfaOffset={cfaOffset}, raOffset={raOffset}"
        echo fmt"  SP=0x{sp.toHex} + {cfaOffset} = CFA=0x{cfa.toHex}"
        echo fmt"  CFA=0x{cfa.toHex} + ({raOffset}) = RA addr=0x{raAddr.toHex}"
      except: discard

    # Validate RA address is within reasonable stack bounds (sframe_stack_example.nim:275)
    # Note: raAddr can equal sp when the return address is stored at the current stack pointer
    if raAddr < sp or raAddr >= sp + 1024'u64:
      when defined(debug):
        try:
          echo fmt"  Invalid RA address (not in stack range 0x{sp.toHex} - 0x{(sp + 1024'u64).toHex})"
        except: discard
      break

    # Read the return address from the stack
    try:
      let nextPc = readU64(raAddr)

      when defined(debug):
        try:
          echo fmt"  Read from raAddr=0x{raAddr.toHex}: nextPc=0x{nextPc.toHex}"
          # Also dump nearby memory for debugging
          if raAddr >= sp and raAddr < sp + 256:
            let offset = raAddr - sp
            echo fmt"  (raAddr is at SP+{offset})"
        except: discard

      # Validate the next PC
      if nextPc == 0 or not isValidCodePointer(nextPc):
        when defined(debug):
          try:
            echo fmt"  Invalid next PC"
          except: discard
        break

      # Update frame state (matching sframe_stack_example.nim:276-277)
      pc = nextPc
      sp = cfa
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

proc captureStackTrace*(maxFrames: int = 64): seq[uint64] {.raises: [], gcsafe, noinline.} =
  ## High-level function to capture a complete stack trace from the current location.
  ## Returns a sequence of program counter (PC) values representing the call stack.

  {.cast(gcsafe).}:
    # Capture SP, FP, and PC directly using inline assembly to avoid function call overhead
    # This matches the approach in sframe_stack_example.nim:228-232
    var sp0, fp0, pc0: uint64
    when defined(amd64) or defined(x86_64):
      {.emit: """
      asm volatile("movq %%rsp, %0" : "=r" (`sp0`));
      asm volatile("movq %%rbp, %0" : "=r" (`fp0`));
      asm volatile("leaq (%%rip), %0" : "=r" (`pc0`));
      """.}
    else:
      sp0 = cast[uint64](nframe_get_sp())
      fp0 = cast[uint64](nframe_get_fp())
      pc0 = cast[uint64](nframe_get_pc())

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
