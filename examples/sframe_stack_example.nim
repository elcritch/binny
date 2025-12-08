## sframe_stack_example.nim - Example demonstrating how to use libsframe for stack tracing
##
## This example shows how to:
## 1. Build and link against libsframe
## 2. Read SFrame data from an executable
## 3. Use sframe_find_fre() to get stack unwinding information
## 4. Perform SP-based stack tracing
##
## NOTE: This is a simplified port of the C version (sframe_stack_example.c).
## It only demonstrates SP-based unwinding, as the Nim compiler currently
## generates FP-based SFrame metadata but doesn't maintain proper frame pointers.

import std/[strformat, strutils, os]

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

type
  SframeRowEntry {.importc: "sframe_frame_row_entry".} = object

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

proc c_sframe_errmsg(err: cint): cstring {.
  importc: "sframe_errmsg", header: "<sframe-api.h>".}

# Constants from sframe-api.h
const
  SFRAME_BASE_REG_FP = 0'u8
  SFRAME_BASE_REG_SP = 1'u8

# Global counter to make stack deeper
var globalCounter = 0

# Structure to hold SFrame section information
type
  SframeInfo = object
    sframeData: seq[byte]
    sframeSize: csize_t
    sframeVaddr: uint64    # Virtual address where sframe section is loaded
    textVaddr: uint64      # Virtual address of .text section
    textSize: uint64       # Size of .text section

# ELF structures (simplified)
type
  Elf64Ehdr {.packed.} = object
    e_ident: array[16, byte]
    e_type: uint16
    e_machine: uint16
    e_version: uint32
    e_entry: uint64
    e_phoff: uint64
    e_shoff: uint64
    e_flags: uint32
    e_ehsize: uint16
    e_phentsize: uint16
    e_phnum: uint16
    e_shentsize: uint16
    e_shnum: uint16
    e_shstrndx: uint16

  Elf64Shdr {.packed.} = object
    sh_name: uint32
    sh_type: uint32
    sh_flags: uint64
    sh_addr: uint64
    sh_offset: uint64
    sh_size: uint64
    sh_link: uint32
    sh_info: uint32
    sh_addralign: uint64
    sh_entsize: uint64

const
  ELFMAG = "\x7FELF"
  SELFMAG = 4

# Find and map the .sframe section from an ELF file
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
    let ehdr = cast[ptr Elf64Ehdr](map)

    # Verify ELF magic
    var magicOk = true
    for i in 0..<SELFMAG:
      if char(ehdr.e_ident[i]) != ELFMAG[i]:
        magicOk = false
        break

    if not magicOk:
      raise newException(ValueError, "Not a valid ELF file")

    # Get section header table
    let shdrTable = cast[ptr UncheckedArray[Elf64Shdr]](cast[uint](map) + uint(ehdr.e_shoff))
    let strTable = cast[ptr UncheckedArray[byte]](cast[uint](map) + uint(shdrTable[ehdr.e_shstrndx].sh_offset))

    # Find .sframe and .text sections
    for i in 0..<int(ehdr.e_shnum):
      let shdr = addr shdrTable[i]

      # Get section name
      let namePtr = cast[ptr UncheckedArray[byte]](cast[uint](strTable) + uint(shdr.sh_name))
      var name = ""
      var j = 0
      while namePtr[j] != 0:
        name.add char(namePtr[j])
        inc j

      if name == ".sframe":
        result.sframeData = newSeq[byte](int(shdr.sh_size))
        let sectionData = cast[ptr UncheckedArray[byte]](cast[uint](map) + uint(shdr.sh_offset))
        copyMem(addr result.sframeData[0], sectionData, int(shdr.sh_size))
        result.sframeSize = csize_t(shdr.sh_size)
        result.sframeVaddr = shdr.sh_addr
        echo fmt"Found .sframe section: size={result.sframeSize}, vaddr=0x{result.sframeVaddr.toHex(6)}"
      elif name == ".text":
        result.textVaddr = shdr.sh_addr
        result.textSize = shdr.sh_size
        echo fmt"Found .text section: vaddr=0x{result.textVaddr.toHex(6)}, size=0x{result.textSize.toHex(6)}"

    if result.sframeData.len == 0:
      raise newException(ValueError, "No .sframe section found")

# Get the current executable path on FreeBSD
proc getExecutablePath(): string =
  when defined(freebsd):
    # On FreeBSD, use sysctl to get the executable path
    type Sysctl {.importc: "sysctl", header: "<sys/sysctl.h>".} = proc(
      mib: ptr cint, miblen: cuint, oldp: pointer, oldlenp: ptr csize_t,
      newp: pointer, newlen: csize_t): cint

    const
      CTL_KERN = 1
      KERN_PROC = 14
      KERN_PROC_PATHNAME = 12

    var mib: array[4, cint] = [cint(CTL_KERN), cint(KERN_PROC), cint(KERN_PROC_PATHNAME), cint(-1)]
    var exePath: array[1024, char]
    var len = csize_t(1024)

    proc c_sysctl(mib: ptr cint, miblen: cuint, oldp: pointer, oldlenp: ptr csize_t,
                  newp: pointer, newlen: csize_t): cint {.importc: "sysctl", header: "<sys/sysctl.h>".}

    if c_sysctl(addr mib[0], 4, addr exePath[0], addr len, nil, 0) == 0:
      result = ""
      for i in 0..<int(len):
        if exePath[i] == '\0':
          break
        result.add exePath[i]
      return result

  # Fallback to getAppFilename()
  return getAppFilename()

# SFrame-based stack unwinding (SP-based only)
proc printSframeStackTrace(dctx: pointer, sframeInfo: SframeInfo) =
  var rsp: uint64
  var frameCount = 0
  const maxFrames = 10

  echo ""
  echo "=== SP-Based Stack Trace ==="

  # Get the current stack pointer
  {.emit: "asm volatile(\"movq %%rsp, %0\" : \"=r\" (`rsp`));".}

  # Get current PC for demonstration
  var currentPc: uint64
  {.emit: "asm volatile(\"leaq (%%rip), %0\" : \"=r\" (`currentPc`));".}

  echo fmt"Starting from SP: 0x{rsp.toHex(10)}, PC: 0x{currentPc.toHex(6)}"

  # Start with current PC and use SFrame to properly unwind
  var pc = currentPc
  var sp = rsp

  while frameCount < maxFrames:
    stdout.write fmt"Frame {frameCount}: PC=0x{pc.toHex(6)} SP=0x{sp.toHex(10)}"

    # Check if PC is in our text section
    if pc >= sframeInfo.textVaddr and pc < (sframeInfo.textVaddr + sframeInfo.textSize):
      var fre: SframeRowEntry 
      # Cast to signed int to handle negative offsets (when PC < sframe_vaddr)
      let pcOffset = cast[int64](pc - sframeInfo.sframeVaddr)
      let lookupPc = int32(pcOffset)
      var err: cint = c_sframe_find_fre(dctx, lookupPc, addr fre)

      if err == 0:

        # Extract unwinding information
        let baseRegId = c_sframe_fre_get_base_reg_id(addr fre, addr err)
        let cfaOffset = c_sframe_fre_get_cfa_offset(dctx, addr fre, addr err)
        if err != 0:
          echo fmt" [Error getting cfaoffset: {err}]"
          break
        let raOffset = c_sframe_fre_get_ra_offset(dctx, addr fre, addr err)


        if err != 0:
          echo fmt" [Error getting base reg: {err}]"
          break

        # Only handle SP-based unwinding

        if baseRegId == SFRAME_BASE_REG_SP:
          # Use SFrame to unwind to next frame
          let cfa = sp + uint64(cfaOffset)
          let raAddr = cast[ptr uint64](cfa + uint64(raOffset))

          stdout.write fmt" -> cfa=0x{cfa.toHex(6)}"

          if cast[uint64](raAddr) > sp and cast[uint64](raAddr) < sp + 1024:
            pc = raAddr[]
            sp = cfa
            stdout.write fmt" next_pc=0x{pc.toHex(6)}]"
          else:
            stdout.write fmt" invalid_ra]"
            echo ""
            break
        else:
          # Skip FP-based frames - Nim doesn't maintain proper frame pointers
          stdout.write " [FP-based - skipping]"
          echo ""
          break
      else:
        stdout.write " [No SFrame] ", err
        echo ""
        break
    else:
      stdout.write " [PC outside text]"
      echo ""
      break

    echo ""
    inc frameCount

    # Safety check
    if pc == 0 or pc < 0x400000:
      break

  echo ""
  echo fmt"Total frames found: {frameCount}"

{.push noinline.}

# Forward declarations
proc stackFunction1(dctx: pointer, sframeInfo: SframeInfo)
proc stackFunction2(dctx: pointer, sframeInfo: SframeInfo)
proc stackFunction3(dctx: pointer, sframeInfo: SframeInfo)
proc stackFunction4(dctx: pointer, sframeInfo: SframeInfo)
proc stackFunction5(dctx: pointer, sframeInfo: SframeInfo)
proc stackFunction6(dctx: pointer, sframeInfo: SframeInfo)

# Function to increment global counter and call next level
proc stackFunction6(dctx: pointer, sframeInfo: SframeInfo) =
  globalCounter += 6
  echo fmt"In stackFunction6, counter = {globalCounter}"
  printSframeStackTrace(dctx, sframeInfo)
  globalCounter -= 6

# Function to increment global counter and call next level
proc stackFunction5(dctx: pointer, sframeInfo: SframeInfo) =
  globalCounter += 5
  echo fmt"In stackFunction5, counter = {globalCounter}"
  stackFunction6(dctx, sframeInfo)
  globalCounter -= 5

# Function to increment global counter and call next level
proc stackFunction4(dctx: pointer, sframeInfo: SframeInfo) =
  echo fmt"In stackFunction4, counter = {globalCounter}"
  stackFunction5(dctx, sframeInfo)

# Function to increment global counter and call next level
proc stackFunction3(dctx: pointer, sframeInfo: SframeInfo) =
  echo fmt"In stackFunction3, counter = {globalCounter}"
  stackFunction4(dctx, sframeInfo)

# Function to increment global counter and call next level
proc stackFunction2(dctx: pointer, sframeInfo: SframeInfo) =
  globalCounter += 2
  echo fmt"In stackFunction2, counter = {globalCounter}"
  stackFunction3(dctx, sframeInfo)
  globalCounter -= 2

# Function to increment global counter and call next level
proc stackFunction1(dctx: pointer, sframeInfo: SframeInfo) =
  globalCounter += 1
  echo fmt"In stackFunction1, counter = {globalCounter}"
  stackFunction2(dctx, sframeInfo)
  globalCounter -= 1

proc main() =
  echo "SFrame Stack Tracing Example"
  echo "============================"

  # Get the current executable path
  let exePath = getExecutablePath()
  let filename = if paramCount() > 0: paramStr(1) else: exePath

  echo fmt"Loading SFrame data from: {filename}"

  # Load SFrame section from ELF file
  let sframeInfo = loadSframeSection(filename)

  # Initialize SFrame decoder
  var err: cint = 0
  let dctx = c_sframe_decode(addr sframeInfo.sframeData[0], sframeInfo.sframeSize, addr err)
  if dctx == nil:
    echo fmt"Failed to initialize SFrame decoder: {c_sframe_errmsg(err)}"
    quit(1)

  defer:
    var ctx = dctx
    c_sframe_decoder_free(addr ctx)

  echo ""
  echo "=== Creating nested function calls to print stack trace ==="

  # Start the chain of function calls that will print the stack trace
  stackFunction1(dctx, sframeInfo)

  echo ""
  echo fmt"Final counter value: {globalCounter}"

when isMainModule:
  main()
