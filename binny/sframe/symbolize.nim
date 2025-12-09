import std/[strutils, os, strformat]

import ../elfparser
import ./types
import ./decoder

export types

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
