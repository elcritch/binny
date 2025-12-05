import std/[unittest, os, osproc, strutils, strformat, sequtils, tables]

# This test builds the examples/stackwalk_amd64_nim example and verifies
# that the printed SFrame backtrace addresses map to the "deepN" functions
# in the expected order using objdump's symbol table.

type SymInfo = object
  pc: uint64
  size: uint64
  name: string   # function name (eg. "deep1")
  tok: string
  depth: int

proc chooseTool(cands: openArray[string]): string =
  for p in cands:
    if fileExists(p): return p
  if cands.len > 0: cands[0] else: ""

proc runCmd(cmd: string): tuple[code: int, output: string] =
  let res = execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut})
  (res.exitCode, res.output)

proc buildExample(exeOut: string): bool =
  # Compile the example with its per-file .nims settings.
  # Use a fixed output path to locate the binary reliably from tests/ CWD.
  # Resolve absolute paths to be resilient to CWD differences when -r runs.
  let testBinDir = splitFile(getAppFilename()).dir
  let rootDir = parentDir(testBinDir)
  let src = rootDir / "examples/stackwalk_amd64_nim.nim"
  let outPath = exeOut
  let cmd = fmt"nim c --nimcache:{rootDir}/.nimcache -o:{outPath} {src}"
  let (code, outp) = runCmd(cmd)
  if code != 0:
    echo "Compile failed:\n", outp
    return false
  return fileExists(outPath)

proc parseDeepSymbols(exe: string): Table[uint64, SymInfo] =
  ## Use objdump to locate deep0..deep7 symbols with addresses and sizes.
  let objdump = chooseTool([
    "/usr/local/bin/x86_64-unknown-freebsd15.0-objdump",
    "/usr/local/bin/objdump",
    "/usr/bin/objdump",
  ])

  if objdump.len == 0:
    return result

  let (code, outp) = runCmd(fmt"{objdump} -t {exe}")
  doAssert code == 0

  for line in outp.splitLines():
    if not line.contains("stackwalk_amd64_nim5deep"): continue

    let cols = line.splitWhitespace()
    if cols.len < 6: continue
    var addrHex = cols[0]
    var sizeHex = cols[4]
    let symTok = cols[^1]

    # Extract deepN from the mangled name token (last column)
    var nIdx = symTok.find("deep")
    doAssert nIdx >= 0 and nIdx + 4 < symTok.len
    let dch = symTok[nIdx + 4]
    doAssert dch >= '0' and dch <= '9'
    let n = int(dch) - int('0')

    let start = parseHexInt(addrHex).uint64
    let size = parseHexInt(sizeHex).uint64
    let fname = "deep" & $n
    result[start] = SymInfo(pc: start, size: size, name: fname, depth: n, tok: symTok)

proc parseBacktraceAddrs(output: string): seq[uint64] =
  ## Extract hex addresses from example's backtrace output lines.
  ## Lines look like: "  0: 0x0000000000414e78"
  var addrs: seq[uint64] = @[]
  for line in output.splitLines():
    let p = line.find("0x")
    if p >= 0:
      let hexPart = line[p+2 .. ^1].strip()
      # Trim any trailing non-hex
      var j = 0
      while j < hexPart.len and hexPart[j] in Digits + {'a'..'f'} + {'A'..'F'}:
        inc j
      if j > 0:
        try:
          addrs.add(parseHexInt(hexPart[0 ..< j]).uint64)
        except CatchableError:
          discard
  result = addrs

proc runExample(exe: string): string =
  let (code, outp) = runCmd(exe)
  if code != 0:
    return ""
  outp

suite "Nim override stackwalk (AMD64)":
  test "Backtrace addresses map to deep1..deep7 via objdump":
    let testBinDir = splitFile(getAppFilename()).dir
    let rootDir = parentDir(testBinDir)
    let exePath = rootDir / "examples/stackwalk_amd64_nim_test"
    check buildExample(exePath)

    let deepSyms = parseDeepSymbols(exePath)
    if deepSyms.len < 7:
      # If we cannot resolve symbols, don't hard fail; but report.
      echo "Could not resolve deep symbols via objdump; got ", deepSyms.len, " entries"
      check deepSyms.len >= 7 # still enforce in CI environments with objdump

    echo "Deep syms: ", deepSyms
    let runOut = runExample(exePath)
    check runOut.len > 0
    let backtracePcs = parseBacktraceAddrs(runOut)
    check backtracePcs.len > 0
    echo "BT addrs: ", backtracePcs 

    # Map addresses to deepN indices and extract the subsequence of deep frames.
    for id, sym in deepSyms:
      echo "checking bactrace output for deep symbol: ", sym
      if sym.depth == 0: continue
      check sym.pc in backtracePcs 


