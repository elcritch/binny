import std/[assertions, json, os, osproc, strutils, tempfiles]
import binny/native_dynlib
import binny/native_dynlib/staticlib

proc run(arguments: openArray[string], expectSuccess = true): string =
  var command: seq[string]
  for argument in arguments:
    command.add argument.quoteShell
  let executed = execCmdEx(command.join(" "))
  doAssert (executed.exitCode == 0) == expectSuccess,
    command.join(" ") & "\n" & executed.output
  result = executed.output

let compiler = getCurrentCompilerExe()
let help = execCmdEx(compiler.quoteShell & " --fullhelp")
when defined(macosx) or defined(linux) or defined(freebsd) or defined(windows):
  if help.exitCode == 0 and "--genBif:on|off" in help.output and
      fileExists(compiler.parentDir / ("nifler" & ExeExt)):
    const source = currentSourcePath.parentDir / "fixtures/native_dynlib_coretypes_producer.nim"
    # Keep Nim's symbol scheme when debug info enables Itanium mangling.
    let testFlags =
      when defined(addressSanitizer): @[
        "--passC:-fsanitize=address -fno-omit-frame-pointer", "--passL:-fsanitize=address",
        "-g", "--mangle:nim", "-d:noSignalHandler",
      ]
      elif defined(danger): @["-d:danger"]
      elif defined(release): @["-d:release"]
      else: newSeq[string]()
    # ELF's incremental PIC recompilation does not forward sanitizer flags.
    const backends = when defined(addressSanitizer): ["c"] else: ["c", "ic"]
    for backend in backends:
      for memoryManager in ["arc", "orc"]:
        let
          temporary = createTempDir("binny-native-coretypes-", "")
          cache = temporary / "cache"
          archive = cache / "backend"
          publicArchive = temporary / "public.a"
          exportsFile = temporary / "exports"
          library = temporary / DynlibFormat.replace("$1", "coretypes")
          bindings = temporary / "coretypes_abi.nim"
          consumer = temporary / "consumer.nim"
        var completed = false
        defer:
          if completed:
            removeDir(temporary)
          else:
            echo "Native core types fixture retained at ", temporary
        createDir(cache)
        var arguments = @[
          compiler, backend, "--genBif:on", "--app:staticlib", "--mm:" & memoryManager,
          "-d:useMalloc", "--nimcache:" & cache, "--out:" & archive,
        ]
        arguments.add testFlags
        when defined(linux) or defined(freebsd):
          if backend == "c":
            arguments.add "--passC:-fPIC"
        discard run(arguments & @[source])
        let exportConfig = initNativeExportConfig()
        let rootSource = nativeCRootSourcePath(cache)
        discard prepareNativeRoutines(cache, source.parentDir, source, rootSource, exportConfig)
        discard run(arguments & @[(if backend == "c": rootSource else: source)])
        let exports = nativeExportSymbols(cache, source.parentDir, exportConfig)
        let initSymbol = nativeInitSymbol(library, findSemanticBifPath(cache, source))
        writeNativeExportList(exportsFile, initSymbol, exports)
        when defined(linux) or defined(freebsd):
          if backend == "ic":
            compileElfPicObjects(cache)
        var archiveArguments =
          when defined(macosx): @["/usr/bin/libtool", "-static", "-o", archive & ".a"]
          else: @["ar", "-rcs", archive & ".a"]
        if backend == "c":
          for node in parseJson(readFile(archive & ".json"))["link"]:
            archiveArguments.add node.getStr
        else:
          for path in walkFiles(cache / "*.o"):
            archiveArguments.add path
        discard run(archiveArguments)
        promoteNativeArchive(archive & ".a", publicArchive, exports)
        let linkerArgs = when defined(addressSanitizer): @["-fsanitize=address"]
                         else: newSeq[string]()
        linkNativeDynlib(publicArchive, library, exportsFile, initSymbol, linkerArgs = linkerArgs)
        let config = initBifNativeBindingsConfig(source, cache, library, source.parentDir)
        doAssert config.writeNativeBindings(bindings)
        let generated = readFile(bindings)
        for expression in [
          "HashSet[int]", "OrderedSet[string]", "CountTable[string]",
          "TableRef[int, string]", "OrderedTableRef[int, string]", "CountTableRef[string]",
          "Deque[HSlice[int, int]]", "Table[string, HashSet[int]]",
          "HashSet[string]", "Deque[int16]",
          "Small* = range[int16(-4)..int16(6)]",
          "Letter* = range[char(97)..char(122)]",
          "Fraction* = range[float32(0.0)..float32(1.0)]",
          "Mid* = range[Level(1)..Level(2)]",
          "ptr UncheckedArray[float32]", "IntRef* = ref int", "IntPtr* = ptr int",
          "proc consumeOwner*(value: sink Owner): int",
          "proc borrowOwner*(holder: OwnerHolder): lent Owner",
          "proc borrowMutable*(holder: OwnerHolder): var Owner",
          "onConsume*: proc(value: sink Owner): int {.closure.}",
          "onBorrow*: proc(): lent Owner {.closure.}",
        ]:
          doAssert expression in generated, expression & " missing from bindings"
        writeFile(consumer, """
import coretypes_abi
import std/[deques, sets, strutils, tables]

let state = newCoreState()
doAssert 2 in state.values
state.values.incl 7
state.ordered.incl "third"
state.counts.inc "apple"
state.tableRef[5] = "five"
state.orderedRef[6] = "six"
state.countRef.inc "pear", 2
state.pending.addLast 3..8
state.nested["nested"] = toHashSet([9])
doAssert state.inspectCoreState()
doAssert roundTripSet(toHashSet(["hello"])) == toHashSet(["hello"])
var queue = initDeque[int16]()
queue.addLast 12'i16
doAssert roundTripDeque(queue).peekFirst() == 12'i16

static:
  doAssert low(Small) == -4 and high(Small) == 6
  doAssert sizeof(Small) == sizeof(int16)
  doAssert low(Letter) == 'a' and high(Letter) == 'z'
  doAssert sizeof(Fraction) == sizeof(float32)
  doAssert low(Wide) == 9223372036854775808'u64
  doAssert high(Wide) == high(uint64)
  doAssert low(Mid) == middleLevel and high(Mid) == highLevel
doAssert roundTripSmall(-3) == -3
doAssert roundTripLetter('b') == 'b'
doAssert roundTripFraction(0.5'f32) == 0.5'f32
doAssert roundTripWide(high(uint64)) == high(uint64)
doAssert roundTripMid(middleLevel) == middleLevel
doAssert anonymousRange(4) == 4
when not defined(danger):
  doAssertRaises RangeDefect:
    let invalid = parseInt("9")
    discard Small(invalid)
var samples = [1.0'f32, 2.0'f32, 3.0'f32]
state.samples = cast[SampleBuffer](addr samples[0])
doAssert sumSamples(cast[ptr UncheckedArray[float32]](addr samples[0]), samples.len) == 6
doAssert sumSamples(nil, 0) == 0
var integer = 9
doAssert increment(addr integer) == addr integer
doAssert integer == 10
var position = 12'i32
state.position = addr position
state.pointRef = new Point
state.pointRef.x = 5
var point = Point(x: 6)
state.pointPtr = addr point
state.integers = newIntRef(7)
state.indexed[-4] = 8
state.letters = {'c'}
doAssert state.inspectBuffers()

proc testOwnership() =
  doAssert destructionCount() == 0
  block:
    var owner = newOwner(41)
    doAssert consumeOwner(ensureMove(owner)) == 41
  doAssert destructionCount() == 1
  doAssert consumeOwner(newOwner(42)) == 42
  doAssert destructionCount() == 2
  doAssert consumeOwners(newOwner(10), newOwner(20)) == 30
  doAssert destructionCount() == 4
  block:
    let holder = newOwnerHolder(43)
    doAssert inspectOwner(holder.borrowOwner()) == 43
    doAssert destructionCount() == 4
    holder.borrowMutable().data[] = 44
    doAssert inspectOwner(holder.borrowOwner()) == 44
    holder.onConsume = proc(value: sink Owner): int = consumeOwner(ensureMove(value))
    doAssert holder.onConsume(newOwner(45)) == 45
    doAssert destructionCount() == 5
    let borrowed = addr holder.value
    holder.onBorrow = proc(): lent Owner = borrowed[]
    doAssert inspectOwner(holder.onBorrow()) == 44
    doAssert destructionCount() == 5
  doAssert destructionCount() == 6
  var strings = @["first", "second"]
  doAssert consumeStrings(strings) == 2
  doAssert strings == @["first", "second"]
  doAssert consumeStrings(ensureMove(strings)) == 2
testOwnership()
""")
        discard run(@[
          compiler, "c", "-r", "--mm:" & memoryManager, "-d:useMalloc",
          "--path:" & temporary, "--nimcache:" & temporary / "consumer-cache",
          "--out:" & temporary / ("consumer" & ExeExt),
        ] & testFlags & @[consumer])
        let copyFailure = temporary / "copy_should_fail.nim"
        writeFile(copyFailure, """
import coretypes_abi
proc cannotCopy() =
  var owner = newOwner(1)
  discard consumeOwner(owner)
  discard inspectOwner(owner)
cannotCopy()
""")
        let failed = run(@[
          compiler, "c", "--mm:" & memoryManager, "-d:useMalloc",
          "--path:" & temporary, "--nimcache:" & temporary / "copy-cache",
          "--out:" & temporary / ("copy_should_fail" & ExeExt),
        ] & testFlags & @[copyFailure], expectSuccess = false)
        doAssert "=dup" in failed or "=copy" in failed, failed
        doAssert "native_dynlib_coretypes_producer.nim" notin readFile(
          temporary / "consumer-cache" / "consumer.json"
        ).replace('\\', '/')
        completed = true
  else:
    echo "Skipping native core types test: compiler lacks BIF support"
