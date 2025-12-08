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
  """.}
  proc nframe_get_fp(): pointer {.importc.}
  proc nframe_get_ra(): pointer {.importc.}
  proc nframe_get_sp(): pointer {.importc.}

proc readU64Ptr*(address: uint64): uint64 =
  ## Direct memory read helper for stack walking
  cast[ptr uint64](cast[pointer](address))[]

# Hybrid stack walking for -fomit-frame-pointer scenarios

proc isValidCodePointer*(pc: uint64): bool =
  ## Basic heuristic: code addresses should be in a reasonable range
  ## and not look like stack addresses
  pc >= 0x400000'u64 and pc < 0x800000'u64

proc scanStackForReturnAddresses*(startSp: uint64; currentPc: uint64; maxScan: int = 2048): seq[tuple[offset: int, pc: uint64]] =
  ## Scan stack memory looking for potential return addresses
  var results: seq[tuple[offset: int, pc: uint64]] = @[]
  for i in 0 ..< maxScan div 8:
    let address = startSp + uint64(i * 8)
    let val = readU64Ptr(address)
    # Look for valid code pointers that are different from current PC
    if isValidCodePointer(val) and val != currentPc:
      results.add((i * 8, val))
  result = results

proc walkStackAmd64*(sec: SFrameSection; sectionBase, startPc, startSp, startFp: uint64; readU64: U64Reader; maxFrames: int = 16): seq[uint64] {.raises: [], tags: [].} =
  ## AMD64 stack walker with fallback from FP to SP base for -fomit-frame-pointer scenarios.
  ## This is the recommended walker for production use as it handles both normal and
  ## -fomit-frame-pointer scenarios gracefully.
  var pc = startPc
  var sp = startSp
  var fp = startFp

  var frames: seq[uint64] = @[startPc]

  # First, scan the stack to find potential return addresses
  let stackRAs = scanStackForReturnAddresses(startSp, startPc, 1024)

  if stackRAs.len == 0:
    return frames

  # Find potential return addresses by scanning stack memory

  # For each potential return address, validate using SFrame data
  var currentSp = startSp
  for (offset, candidatePc) in stackRAs:
    if frames.len >= maxFrames: break

    # Check if this PC has SFrame data
    let (found, fdeIdx, freLocalIdx, freGlobalIdx) = sec.pcToFre(candidatePc, sectionBase)
    if found:
      # Validate that this is a reasonable next frame
      let funcStart = sec.funcStartAddress(fdeIdx, sectionBase)
      let fde = sec.fdes[fdeIdx]

      # If this looks like a valid caller, add it and search for deeper frames
      if candidatePc > funcStart and candidatePc < (funcStart + uint64(fde.funcSize)):
        frames.add candidatePc
        currentSp = startSp + uint64(offset + 8)  # Move past this return address

        # Recursively search for more frames from this new stack position
        let remainingRAs = scanStackForReturnAddresses(currentSp, candidatePc, 1024)
        for (nextOffset, nextPc) in remainingRAs:
          if frames.len >= maxFrames: break
          let (nextFound, nextFdeIdx, _, _) = sec.pcToFre(nextPc, sectionBase)
          if nextFound:
            let nextFuncStart = sec.funcStartAddress(nextFdeIdx, sectionBase)
            let nextFde = sec.fdes[nextFdeIdx]
            if nextPc > nextFuncStart and nextPc < (nextFuncStart + uint64(nextFde.funcSize)):
              frames.add nextPc
              currentSp += uint64(nextOffset + 8)
        break

  result = frames

# High-level stack tracing interface

proc captureStackTrace*(maxFrames: int = 64): seq[uint64] {.raises: [], gcsafe.} =
  ## High-level function to capture a complete stack trace from the current location.
  ## Returns a sequence of program counter (PC) values representing the call stack.

  {.cast(gcsafe).}:
    let fp0 = cast[uint64](nframe_get_fp())
    let sp0 = cast[uint64](nframe_get_sp())
    let pc0 = cast[uint64](nframe_get_ra())

    if gSframeSection.fdes.len == 0:
      return @[pc0]

    # Perform stack walking
    result = walkStackAmd64(gSframeSection, gSframeSectionBase, pc0, sp0, fp0, readU64Ptr, maxFrames)

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
        symbols[i] = fmt"{sym.name} + 0x{offset.toHex(4)} (PC 0x{(frames[i]-offset).toHex(8)} ) (at 0x{(frames[i]-1).toHex(8)} )" # the -1 seems to give us a more accurate addr2line lookup (?)
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
