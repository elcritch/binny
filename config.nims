# NimScript configuration and tasks for this repo
switch("nimcache", ".nimcache")

import std/[os, strformat, strutils]

const testDir = "tests"

task test, "Compile and run all tests in tests/":
  withDir(testDir):
    for kind, path in walkDir("."):
      if kind == pcFile and path.endsWith(".nim") and not path.endsWith("config.nims"):
        let name = splitFile(path).name
        if not name.startsWith("t"): continue # run only t*.nim files
        if name.startsWith("test_libsframe_comparison"): continue
        echo fmt"[sigils] Running {path}"
        exec fmt"nim c -r {path}"

task testLibSframe, "test our sframe impl against libsframe":
  exec "nim c -r tests/test_libsframe_comparison.nim"

