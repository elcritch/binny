import std/[unittest, os, osproc, strutils, strformat, sequtils]

# This test builds and runs examples/stackwalk_amd64_nim.nim (which enables
# the Nim stacktrace override), then validates that the printed backtrace
# contains the expected deep0..deep7 functions in order.

proc runCmd(cmd: string): tuple[code: int, output: string] =
  let res = execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut})
  (res.exitCode, res.output)

proc buildExample(exeOut: string): bool =
  # Compile the example with its per-file .nims settings and a fixed output.
  let testBinDir = splitFile(getAppFilename()).dir
  let rootDir = parentDir(testBinDir)
  let src = rootDir / "examples/stackwalk_amd64_override.nim"
  let outPath = exeOut
  let cmd = fmt"nim c -o:{outPath} {src}"
  let (code, outp) = runCmd(cmd)
  if code != 0:
    echo "Compile failed:\n", outp
    return false
  return fileExists(outPath)

proc runExample(exe: string): tuple[code: int, outp: string] =
  let r = runCmd(exe)
  (code: r.code, outp: r.output)

proc parseDeepFromOutput(output: string): seq[string] =
  ## Extract lines like "stackwalk_amd64_nim::deepN() + 0x..." and return the function names
  for line in output.splitLines():
    let trimmed = line.strip()
    if "stackwalk_amd64_override::deep" in trimmed:
      let namePart = trimmed.split(" + ")[0]
      if namePart.endsWith(")"):
        let parts = namePart.split("::")
        let fn = parts[parts.len-1]
        result.add fn

proc isSubsequence(hay: openArray[string]; needle: openArray[string]): bool =
  var i = 0
  for x in hay:
    if i < needle.len and x == needle[i]: inc i
  i == needle.len

when defined(amd64):
  suite "Nim override stackwalk (AMD64)":
    test "Printed backtrace contains deep0..deep7 in order":
      let testBinDir = splitFile(getAppFilename()).dir
      let rootDir = parentDir(testBinDir)
      let exePath = rootDir / "examples/stackwalk_amd64_override"
      check buildExample(exePath)

      let (code, runOut) = runExample(exePath)
      # The example terminates with an exception; non-zero exit is OK.
      check runOut.len > 0

      let deeps = parseDeepFromOutput(runOut)
      check deeps.len >= 8

      let expected = @["deep0()", "deep1()", "deep2()", "deep3()", "deep4()", "deep5()", "deep6()", "deep7()"]
      check isSubsequence(deeps, expected)
