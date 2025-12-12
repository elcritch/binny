import std/[algorithm, sequtils, strformat]
import ../elfparser
import ../sframe

# DWARF → SFrame conversion utilities.
#
# This provides a minimal, pragmatic conversion that constructs an SFrame
# section using ELF function symbols for FDE boundaries and simple FREs.
# It does not currently parse DWARF CFI; instead, it emits a single FRE per
# function with a conservative stack model suitable for basic validation and
# experimentation.

type Dwarf2SframeError* = object of CatchableError

proc detectAbi*(elf: ElfFile): SFrameAbiArch =
  ## Infer SFrame ABI arch from the ELF header. Currently supports amd64.
  # EM_X86_64 = 62
  const EM_X86_64 = 62'u16
  if elf.header.e_machine == EM_X86_64:
    return sframeAbiAmd64Little
  sframeAbiInvalid

proc buildSFrameFromElf*(elf: ElfFile): SFrameSection =
  ## Convert basic DWARF/ELF information into an SFrameSection.
  ##
  ## Strategy:
  ## - Use function symbols as FDE boundaries (start address + size).
  ## - Emit exactly one FRE per function with startAddr = 0.
  ## - For amd64, use CFA base = SP with a single 1-byte CFA offset (0).
  ## - Use fixed RA-from-CFA offset in the header (8) as a reasonable default.
  ##
  ## This is intentionally conservative and geared towards producing a valid
  ## SFrame encoding that can be inspected and validated; it is not a full
  ## DWARF CFI to SFrame converter.
  let abi = detectAbi(elf)
  if abi == sframeAbiInvalid:
    raise newException(
      Dwarf2SframeError,
      fmt"Unsupported ELF e_machine={elf.header.e_machine} for SFrame conversion",
    )

  var funcs = elf.getFunctionSymbols()
  # Filter out zero-sized or zero-address entries just in case.
  funcs = funcs.filterIt(it.size > 0 and it.value != 0)
  if funcs.len == 0:
    raise newException(Dwarf2SframeError, "No function symbols to convert")

  # Sort by start address so we can set the FDE_SORTED flag.
  funcs.sort(proc(a, b: ElfSymbol): int =
    if a.value < b.value: -1 elif a.value > b.value: 1 else: 0)

  # Header
  var hdr = SFrameHeader(
    preamble: SFramePreamble(magic: SFRAME_MAGIC, version: SFRAME_VERSION_2, flags: 0),
    abiArch: uint8(abi),
    cfaFixedFpOffset: 0'i8,
    cfaFixedRaOffset: 8'i8, # amd64 typical return address distance from CFA at call site
    auxHdrLen: 0'u8,
    numFdes: 0'u32, # filled by encoder
    numFres: 0'u32,
    freLen: 0'u32,
    fdeOff: 0'u32,
    freOff: 0'u32,
    auxData: @[]
  )
  # Mark FDEs as sorted by start address
  hdr.preamble.flags = uint8(SFRAME_F_FDE_SORTED) or hdr.preamble.flags

  # For now we choose 4-byte FRE startAddr fields to keep things simple.
  let freType = sframeFreAddr4
  let fdeType = sframeFdePcInc

  var fdes: seq[SFrameFDE] = @[]
  var fres: seq[SFrameFRE] = @[]

  for sym in funcs:
    # Construct one FRE at start offset 0 with a single 1-byte CFA offset of 0.
    let finfo = freInfo(
      cfaBase = sframeCfaBaseSp,
      offsetCount = 1, # only CFA-from-base included
      offsetSize = sframeFreOff1B,
      mangledRa = false,
    )
    let fre = SFrameFRE(
      startAddr: 0'u32,
      info: finfo,
      offsets: @[0'i32],
    )
    fres.add(fre)

    # Build FDE; funcStartFreOff is filled by encoder.encodeSection.
    let infoWord = fdeInfo(freType = freType, fdeType = fdeType)
    var fde = SFrameFDE(
      funcStartAddress: int32(sym.value and 0xFFFF_FFFF'u64),
      funcSize: uint32(sym.size and 0xFFFF_FFFF'u64),
      funcStartFreOff: 0'u32,
      funcNumFres: 1'u32,
      funcInfo: infoWord,
      funcRepSize: 0'u8,
      funcPadding2: 0'u16,
    )
    fdes.add(fde)

  SFrameSection(header: hdr, fdes: fdes, fres: fres)

