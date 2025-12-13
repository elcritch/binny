import std/[algorithm, options, sequtils, strformat]
import ../elfparser
import ../dwarf/cfi
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

proc buildSFrameFromElfWithBase*(elf: ElfFile): tuple[sec: SFrameSection, base: uint64] =
  ## Convert basic DWARF/ELF information into an SFrameSection.
  ##
  ## Strategy:
  ## - Prefer parsing DWARF CFI from .eh_frame when available.
  ## - Fall back to function symbols if CFI is missing/unsupported.
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

  # Header
  var hdr = SFrameHeader(
    preamble: SFramePreamble(magic: SFRAME_MAGIC, version: SFRAME_VERSION_2, flags: 0),
    abiArch: uint8(abi),
    cfaFixedFpOffset: 0'i8,
    cfaFixedRaOffset: -8'i8, # amd64: saved RA is typically at CFA-8
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

  var fdes: seq[SFrameFDE] = @[]
  var fres: seq[SFrameFRE] = @[]

  var base: uint64 = 0
  var usedFp = false

  when defined(amd64):
    const
      dwarfRegFp = 6'u64 # rbp
      dwarfRegSp = 7'u64 # rsp

    try:
      let pairs = parseDwarfCfi(elf, cfiEhFrame)
      if pairs.len == 0:
        raise newException(Dwarf2SframeError, "No FDEs found in .eh_frame")

      var sortedPairs = pairs
      sortedPairs.sort(proc(a, b: tuple[fde: DwarfFde, cie: DwarfCie]): int =
        if a.fde.initialLocation < b.fde.initialLocation: -1
        elif a.fde.initialLocation > b.fde.initialLocation: 1
        else: 0)

      base = sortedPairs[0].fde.initialLocation

      for pair in sortedPairs:
        let fdeIn = pair.fde
        let cieIn = pair.cie
        var rows = computeCfiRows(fdeIn, cieIn, fpReg = dwarfRegFp)
        if rows.len == 0:
          continue

        var funcFres: seq[SFrameFRE] = @[]
        var lastCfaReg: uint64 = 0
        var lastCfaOff: int64 = 0
        var lastFpOff: Option[int64] = none(int64)
        var first = true

        for row in rows:
          let cfaReg = row.cfaReg
          let cfaOff = row.cfaOffset
          let fpOff = row.fpOffset
          if not first and cfaReg == lastCfaReg and cfaOff == lastCfaOff and fpOff == lastFpOff:
            continue
          first = false
          lastCfaReg = cfaReg
          lastCfaOff = cfaOff
          lastFpOff = fpOff

          let startOff = row.address - fdeIn.initialLocation
          if startOff > uint64(high(uint32)):
            raise newException(Dwarf2SframeError, "CFI row offset exceeds 32-bit range")

          var cfaBase = sframeCfaBaseSp
          if cfaReg == dwarfRegFp:
            cfaBase = sframeCfaBaseFp
            usedFp = true
          elif cfaReg == dwarfRegSp:
            cfaBase = sframeCfaBaseSp

          var offsets: seq[int32] = @[]
          if cfaOff < int64(low(int32)) or cfaOff > int64(high(int32)):
            raise newException(Dwarf2SframeError, "CFA offset exceeds 32-bit range")
          offsets.add(int32(cfaOff))

          var offsetCount = 1
          if fpOff.isSome:
            let v = fpOff.get()
            if v < int64(low(int32)) or v > int64(high(int32)):
              raise newException(Dwarf2SframeError, "FP offset exceeds 32-bit range")
            offsets.add(int32(v))
            offsetCount = 2

          let finfo = freInfo(
            cfaBase = cfaBase,
            offsetCount = offsetCount,
            offsetSize = sframeFreOff4B,
            mangledRa = false,
          )
          funcFres.add(
            SFrameFRE(startAddr: uint32(startOff), info: finfo, offsets: offsets)
          )

        if funcFres.len == 0:
          continue

        var maxSa: uint32 = 0
        for fr in funcFres:
          if fr.startAddr > maxSa:
            maxSa = fr.startAddr
        let freType =
          if maxSa <= 0xFF'u32: sframeFreAddr1
          elif maxSa <= 0xFFFF'u32: sframeFreAddr2
          else: sframeFreAddr4

        if fdeIn.addressRange > uint64(high(uint32)):
          raise newException(Dwarf2SframeError, "FDE range exceeds 32-bit range")
        let relStart = fdeIn.initialLocation - base
        if relStart > uint64(high(int32)):
          raise newException(Dwarf2SframeError, "FDE start exceeds 32-bit signed range")

        fdes.add(
          SFrameFDE(
            funcStartAddress: int32(relStart),
            funcSize: uint32(fdeIn.addressRange),
            funcStartFreOff: 0'u32,
            funcNumFres: uint32(funcFres.len),
            funcInfo: fdeInfo(freType = freType, fdeType = sframeFdePcInc),
            funcRepSize: 0'u8,
            funcPadding2: 0'u16,
          )
        )
        for fr in funcFres:
          fres.add(fr)

    except CatchableError:
      # Fall back to symbol-based conversion below.
      discard

  if fdes.len == 0:
    var funcs = elf.getFunctionSymbols()
    funcs = funcs.filterIt(it.size > 0 and it.value != 0)
    if funcs.len == 0:
      raise newException(Dwarf2SframeError, "No function symbols to convert")

    funcs.sort(proc(a, b: ElfSymbol): int =
      if a.value < b.value: -1 elif a.value > b.value: 1 else: 0)
    base = funcs[0].value

    for sym in funcs:
      let relStart = sym.value - base
      if relStart > uint64(high(int32)):
        raise newException(Dwarf2SframeError, "Symbol start exceeds 32-bit signed range")
      let finfo = freInfo(
        cfaBase = sframeCfaBaseSp,
        offsetCount = 1,
        offsetSize = sframeFreOff4B,
        mangledRa = false,
      )
      fres.add(SFrameFRE(startAddr: 0'u32, info: finfo, offsets: @[0'i32]))
      fdes.add(
        SFrameFDE(
          funcStartAddress: int32(relStart),
          funcSize: uint32(sym.size),
          funcStartFreOff: 0'u32,
          funcNumFres: 1'u32,
          funcInfo: fdeInfo(freType = sframeFreAddr1, fdeType = sframeFdePcInc),
          funcRepSize: 0'u8,
          funcPadding2: 0'u16,
        )
      )

  if usedFp:
    hdr.preamble.flags = uint8(SFRAME_F_FRAME_POINTER) or hdr.preamble.flags

  result.sec = SFrameSection(header: hdr, fdes: fdes, fres: fres)
  result.base = base

proc buildSFrameFromElf*(elf: ElfFile): SFrameSection =
  buildSFrameFromElfWithBase(elf).sec
