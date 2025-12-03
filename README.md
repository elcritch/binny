SFrame (Nim) — minimal implementation and walkers

This repo contains a minimal Nim implementation of the SFrame v2 format (see docs/sframe-spec.md), including:

- Core types and encode/decode: `sframe.nim`
- AMD64 stack walker + simulated memory: `sframe/amd64_walk.nim`
- AArch64 stack walker + simulated memory: `sframe/aarch64_walk.nim`

Running tests

- `nim c -r tests/tfile.nim`
- `nim c -r tests/twalk_amd64.nim`
- `nim c -r tests/twalk_aarch64.nim`

Quick usage (AMD64)

```
import sframe
import sframe/amd64_walk

# Build or parse an SFrameSection named `sec` and compute `sectionBase`.

# Initialize simulated memory for example purposes (your tracer would read live memory):
var mem = initSimMemory(0x70000000'u64, 0x1000)

# Starting registers for the topmost frame (PC/SP/FP):
let startPc = sectionBase + 0x1000'u64 + 4'u64
let startSp = 0x70000020'u64
let startFp = 0'u64

# Walk up to 16 frames; returns a list of PCs
let frames = walkStackAmd64(sec, sectionBase, startPc, startSp, startFp, mem, maxFrames = 16)
```

For AArch64, import `sframe/aarch64_walk` and call `walkStackAarch64` with the same arguments.

Notes

- The walkers use SFrame FRE semantics to compute CFA, RA, and FP locations.
- AMD64 uses `header.cfaFixedRaOffset` for RA; AArch64 uses RA/FP offsets from FRE.
- This is a minimal implementation for testing and experimentation; not a full tracer.

Decode an existing .sframe section file

- Extract the `.sframe` section from an ELF binary (GNU objcopy or llvm-objcopy):
  - `objcopy --dump-section .sframe=out.sframe your.elf`
  - or `llvm-objcopy --dump-section .sframe=out.sframe your.elf`
- Dump it with the included tool:
  - `nim c -r tools/sframe_dump.nim out.sframe` (assumes function start addresses are relative to section base 0)
  - You can provide the section base address if needed (e.g., when `SFRAME_F_FDE_FUNC_START_PCREL` is set or to compute absolute PCs):
    - `nim c -r tools/sframe_dump.nim out.sframe --base=0x7f000000`


SFrame section layout

The `.sframe` section contains:

- Preamble (4 bytes)
  - `magic` (uint16 = 0xDEE2)
  - `version` (uint8 = 2)
  - `flags` (uint8)
- Header (fixed 24 bytes after preamble; total 28) plus optional aux header
  - `abiArch` (uint8)
  - `cfaFixedFpOffset` (int8)
  - `cfaFixedRaOffset` (int8)
  - `auxHdrLen` (uint8)
  - `numFdes` (uint32)
  - `numFres` (uint32)
  - `freLen` (uint32)
  - `fdeOff` (uint32) — offset from end of header
  - `freOff` (uint32) — offset from end of header
- FDE sub-section: array of `numFdes` fixed 20-byte entries
- FRE sub-section: `freLen` bytes (variable-sized entries)

High-level diagram

```
| Preamble (4) | Header (24 + aux) | FDE array (20 * numFdes) | FRE bytes (freLen) |
                                   ^ fdeOff=0 typically        ^ freOff = 20*numFdes
```

Key details

- Endianness: all fields stored in target endianness; this impl uses host endianness for simplicity.
- FDE.funcStartAddress:
  - Absolute-from-section-start or PC-relative-from-field depending on `SFRAME_F_FDE_FUNC_START_PCREL` flag.
- FDE.funcStartFreOff: offset to function’s first FRE relative to start of FRE sub-section.
- FRE start address width: 1/2/4 bytes chosen per-function via FDE info word (ADDR1/ADDR2/ADDR4).
- FRE info word encodes CFA base (SP/FP), number of offsets, and offset size (1/2/4).
