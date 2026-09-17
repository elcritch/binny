import std/[assertions, os, osproc, strutils, tempfiles]
import binny/native_dynlib

proc run(arguments: openArray[string]): string =
  var command: seq[string]
  for argument in arguments:
    command.add argument.quoteShell
  let executed = execCmdEx(command.join(" "))
  doAssert executed.exitCode == 0, executed.output
  result = executed.output

proc supportsBif(compiler: string): bool =
  let help = execCmdEx(compiler.quoteShell & " --fullhelp")
  result =
    (defined(macosx) or defined(linux) or defined(freebsd) or defined(windows)) and
    help.exitCode == 0 and "--genBif:on|off" in help.output and
    fileExists(compiler.parentDir / ("nifler" & ExeExt))

when defined(macosx) or defined(linux) or defined(freebsd) or defined(windows):
  let compiler = getCurrentCompilerExe()
  if compiler.supportsBif:
    const
      projectRoot = currentSourcePath.parentDir.parentDir
      producerSource = projectRoot / "tests/fixtures/native_dynlib_bumpy_producer.nim"
      bumpySource = projectRoot / "deps/bumpy/src"
      vmathSource = projectRoot / "deps/vmath/src"

    if not fileExists(bumpySource / "bumpy.nim") or
        not fileExists(vmathSource / "vmath.nim"):
      echo "Skipping imported bumpy type test: run atlas install --feature:test"
    else:
      let
        temporary = createTempDir("binny-native-imported-type-", "")
        cache = temporary / "nimcache"
        backend = cache / "producer-backend"
        exportConfigPath = temporary / "native_dynlib.json"
        bindings = temporary / "bumpy_abi.nim"
        consumer = temporary / "consumer.nim"
        consumerCache = cache / "consumer"
        consumerBinary = temporary / ("consumer" & ExeExt)
      defer:
        removeDir(temporary)

      createDir(cache)
      discard run(
        [
          compiler,
          "ic",
          "--genBif:on",
          "--app:staticlib",
          "--mm:arc",
          "-d:useMalloc",
          "--path:" & bumpySource,
          "--path:" & vmathSource,
          "--nimcache:" & cache,
          "--out:" & backend,
          producerSource,
        ]
      )

      writeFile(
        exportConfigPath,
        """
{
  "typeImports": [
    {"name": "Rect", "module": "bumpy"}
  ]
}
""",
      )
      let config = initBifNativeBindingsConfig(
        producerSource,
        cache,
        temporary / "libbumpy",
        producerSource.parentDir,
        loadNativeExportConfig(exportConfigPath),
      )
      doAssert config.writeNativeBindings(bindings)
      let generated = readFile(bindings)
      doAssert "import bumpy" in generated
      doAssert "export bumpy.Rect" in generated
      doAssert "  Rect* = object" notin generated
      doAssert "proc identityRect*(value: Rect): Rect" in generated
      doAssert "doAssert sizeof(Rect) == 16" in generated
      doAssert "doAssert alignof(Rect) == 4" in generated
      doAssert "doAssert offsetOf(Rect, x) == 0" in generated
      doAssert "doAssert offsetOf(Rect, h) == 12" in generated

      writeFile(
        consumer,
        """
import bumpy_abi

let result = identityRect(Rect(x: 1, y: 2, w: 3, h: 4))
doAssert result.x == 1
doAssert result.y == 2
doAssert result.w == 3
doAssert result.h == 4
""",
      )
      discard run(
        [
          compiler,
          "c",
          "--mm:arc",
          "-d:useMalloc",
          "--path:" & bumpySource,
          "--path:" & vmathSource,
          "--path:" & temporary,
          "--nimcache:" & consumerCache,
          "--out:" & consumerBinary,
          consumer,
        ]
      )
  else:
    echo "Skipping imported bumpy type test: current Nim lacks --genBif/nifler"
