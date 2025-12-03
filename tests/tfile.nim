import std/[unittest]
import sframe

suite "SFrame minimal":
  test "Preamble struct size is 4 bytes":
    check sizeof(SFramePreamble) == 4

  test "Preamble encode/decode roundtrip (host endian)":
    let pre = SFramePreamble(magic: SFRAME_MAGIC, version: SFRAME_VERSION_2, flags: 0'u8)
    check pre.isValid()
    let bytes = encodePreamble(pre)
    let pre2 = decodePreamble(bytes)
    check pre2 == pre

  test "Header fixed size and roundtrip":
    var h = SFrameHeader(
      preamble: SFramePreamble(magic: SFRAME_MAGIC, version: SFRAME_VERSION_2, flags: uint8(SFRAME_F_FDE_SORTED) or uint8(SFRAME_F_FRAME_POINTER)),
      abiArch: uint8(sframeAbiAmd64Little),
      cfaFixedFpOffset: 0'i8,
      cfaFixedRaOffset: -8'i8,
      auxHdrLen: 0'u8,
      numFdes: 1'u32,
      numFres: 2'u32,
      freLen: 0'u32,
      fdeOff: 0'u32,
      freOff: 20'u32,
      auxData: @[]
    )
    check sizeofSFrameHeaderFixed() == 28
    let enc = encodeHeader(h)
    check enc.len == 28
    let dec = decodeHeader(enc)
    check dec.preamble == h.preamble
    check dec.abiArch == h.abiArch
    check dec.cfaFixedFpOffset == h.cfaFixedFpOffset
    check dec.cfaFixedRaOffset == h.cfaFixedRaOffset
    check dec.auxHdrLen == h.auxHdrLen
    check dec.numFdes == h.numFdes
    check dec.numFres == h.numFres
    check dec.freLen == h.freLen
    check dec.fdeOff == h.fdeOff
    check dec.freOff == h.freOff

  test "FDE info word helpers and size":
    let info = fdeInfo(sframeFreAddr2, sframeFdePcMask, aarch64PauthKeyB=true)
    check fdeInfoGetFreType(info) == sframeFreAddr2
    check fdeInfoGetFdeType(info) == sframeFdePcMask
    check fdeInfoGetAarch64PauthKeyB(info) == true
    check sizeofSFrameFDE() == 20

  test "FDE encode/decode roundtrip":
    let fi = fdeInfo(sframeFreAddr1, sframeFdePcInc)
    var fde = SFrameFDE(
      funcStartAddress: 0x1000'i32,
      funcSize: 0x200'u32,
      funcStartFreOff: 0'u32,
      funcNumFres: 3'u32,
      funcInfo: fi,
      funcRepSize: 0'u8,
      funcPadding2: 0'u16
    )
    let encf = encodeFDE(fde)
    check encf.len == 20
    let decf = decodeFDE(encf)
    check decf.funcStartAddress == fde.funcStartAddress
    check decf.funcSize == fde.funcSize
    check decf.funcStartFreOff == fde.funcStartFreOff
    check decf.funcNumFres == fde.funcNumFres
    check decf.funcInfo == fde.funcInfo
    check decf.funcRepSize == fde.funcRepSize
    check decf.funcPadding2 == fde.funcPadding2

  test "FRE info helpers":
    let inf = freInfo(sframeCfaBaseFp, 3, sframeFreOff2B, mangledRa=true)
    check freInfoGetCfaBase(inf) == sframeCfaBaseFp
    check freInfoGetOffsetCount(inf) == 3
    check freInfoGetOffsetSize(inf) == sframeFreOff2B
    check freInfoGetMangledRa(inf) == true
    check inf.freInfoOffsetByteSize() == 2

  test "FRE encode/decode (ADDR1, off1B)":
    let inf = freInfo(sframeCfaBaseSp, 2, sframeFreOff1B)
    var fre = SFrameFRE(startAddr: 0x12'u32, info: inf, offsets: @[int32(-8), int32(16)])
    let b = encodeFRE(fre, sframeFreAddr1)
    let (dec, used) = decodeFRE(b, sframeFreAddr1)
    check used == b.len
    check dec.startAddr == fre.startAddr
    check dec.info == fre.info
    check dec.offsets == fre.offsets

  test "FRE encode/decode (ADDR2, off2B)":
    let inf = freInfo(sframeCfaBaseFp, 3, sframeFreOff2B)
    var fre = SFrameFRE(startAddr: 0x1234'u32, info: inf, offsets: @[int32(64), int32(-8), int32(0)])
    let b = encodeFRE(fre, sframeFreAddr2)
    let (dec, used) = decodeFRE(b, sframeFreAddr2)
    check used == b.len
    check dec.startAddr == fre.startAddr
    check dec.info == fre.info
    check dec.offsets == fre.offsets

  test "FRE encode/decode (ADDR4, off4B)":
    let inf = freInfo(sframeCfaBaseSp, 1, sframeFreOff4B)
    var fre = SFrameFRE(startAddr: 0x12345678'u32, info: inf, offsets: @[int32(-4)])
    let b = encodeFRE(fre, sframeFreAddr4)
    let (dec, used) = decodeFRE(b, sframeFreAddr4)
    check used == b.len
    check dec.startAddr == fre.startAddr
    check dec.info == fre.info
    check dec.offsets == fre.offsets

  test "Section encode/decode simple":
    # Build a section with one function and two FREs
    var sec = SFrameSection(
      header: SFrameHeader(
        preamble: SFramePreamble(magic: SFRAME_MAGIC, version: SFRAME_VERSION_2, flags: uint8(SFRAME_F_FDE_SORTED)),
        abiArch: uint8(sframeAbiAmd64Little),
        cfaFixedFpOffset: 0'i8,
        cfaFixedRaOffset: -8'i8,
        auxHdrLen: 0'u8,
        auxData: @[]
      ),
      fdes: @[
        SFrameFDE(
          funcStartAddress: 0x1000'i32,
          funcSize: 0x80'u32,
          funcStartFreOff: 0'u32,
          funcNumFres: 2'u32,
          funcInfo: fdeInfo(sframeFreAddr1, sframeFdePcInc),
          funcRepSize: 0'u8,
          funcPadding2: 0'u16
        )
      ],
      fres: @[
        SFrameFRE(startAddr: 0'u32, info: freInfo(sframeCfaBaseSp, 1, sframeFreOff1B), offsets: @[int32(16)]),
        SFrameFRE(startAddr: 8'u32, info: freInfo(sframeCfaBaseSp, 2, sframeFreOff1B), offsets: @[int32(16), int32(-8)])
      ]
    )
    let bytes = encodeSection(sec)
    # Header adjustments
    check sec.header.numFdes == 1
    check sec.header.numFres == 2
    check sec.header.fdeOff == 0
    check sec.header.freOff == uint32(sizeofSFrameFDE())
    # FDE fre offset should be 0 as first FRE starts at start of FRE sub-section
    check sec.fdes[0].funcStartFreOff == 0
    let dec = decodeSection(bytes)
    check dec.header.numFdes == 1
    check dec.header.numFres == 2
    check fdeInfoGetFreType(dec.fdes[0].funcInfo) == sframeFreAddr1
    check dec.fres.len == 2
