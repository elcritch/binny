import std/[assertions, os, osproc, strutils, tempfiles]
import binny/native_dynlib
import binny/native_dynlib/staticlib

proc quoteShell(value: string): string =
  result = "'"
  for character in value:
    if character == '\'':
      result.add "'\"'\"'"
    else:
      result.add character
  result.add "'"

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
    fileExists(compiler.parentDir / "nifler")

when defined(macosx) or defined(linux) or defined(freebsd) or defined(windows):
  let compiler = getCurrentCompilerExe()
  if compiler.supportsBif:
    let
      temporary = createTempDir("binny-native-anonymous-generics-", "")
      source = temporary / "producer.nim"
      cache = temporary / "nimcache"
      backend = cache / "producer-backend"
      dylib =
        when defined(macosx):
          temporary / "libproducer.dylib"
        elif defined(windows):
          temporary / "libproducer.dll"
        else:
          temporary / "libproducer.so"
      bindings = temporary / "producer_abi.nim"
    defer:
      removeDir(temporary)

    writeFile(
      source,
      """
type
  Axis = enum
    x, y, z, w

  Node = ref object
    next: Node
    children: seq[Node]

  PublicNode* = ref object
    next*: PublicNode
    children*: seq[PublicNode]

  PublicTree* = object
    root*: PublicNode

  Box[T] = object
    value: T

  Pair[K, V] = object
    key: K
    value: V

  RecursiveBox[T] = ref object
    value: T
    next: RecursiveBox[T]
    children: seq[RecursiveBox[T]]

proc sumSequence*(values: seq[int]): int {.noinline.} =
  for value in values:
    result += value

proc sumFixedArray*(values: array[4, int]): int {.noinline.} =
  for value in values:
    result += value

proc sumEnumArray*(values: array[Axis, int]): int {.noinline.} =
  for value in values:
    result += value

proc sumNestedSequence*(values: seq[array[4, int]]): int {.noinline.} =
  for value in values:
    result += value[0]

proc sumNestedArray*(values: array[4, seq[int]]): int {.noinline.} =
  for value in values:
    if value.len > 0:
      result += value[0]

proc identityNode*(value: Node): Node {.noinline.} =
  value

proc identityPublicNode*(value: PublicNode): PublicNode {.noinline.} =
  value

proc publicChildren*(value: PublicNode): seq[PublicNode] {.noinline.} =
  value.children

proc identityPublicTree*(value: PublicTree): PublicTree {.noinline.} =
  value

proc sumBox*(value: Box[int]): int {.noinline.} =
  value.value

proc sumPair*(value: Pair[int, bool]): int {.noinline.} =
  if value.value: value.key else: 0

proc sumNestedBox*(value: Box[seq[array[4, int]]]): int {.noinline.} =
  if value.value.len > 0: value.value[0][0] else: 0

proc identityRecursiveBox*(value: RecursiveBox[int]): RecursiveBox[int] {.noinline.} =
  value
""",
    )
    createDir(cache)

    discard run(
      [
        compiler,
        "ic",
        "--genBif:on",
        "--app:staticlib",
        "--mm:orc",
        "-d:useMalloc",
        "--nimcache:" & cache,
        "--out:" & backend,
        source,
      ]
    )

    let bifPath = findSemanticBifPath(cache, source)
    # This branch deliberately consumes plain devel BIF output. The compiler
    # type graph supplies the generic arguments through TType.sonsImpl, so no
    # producer-side genericargs extension is needed.
    doAssert "genericargs" notin readFile(bifPath)
    let config = initBifNativeBindingsConfig(source, cache, dylib, temporary)
    doAssert config.writeNativeBindings(bindings)
    let generatedBindings = readFile(bindings)
    doAssert "proc sumSequence*(values: seq[int]): int" in generatedBindings
    doAssert "proc sumFixedArray*(values: array[4, int]): int" in generatedBindings
    doAssert "proc sumEnumArray*(values: array[NativeAbi" in generatedBindings
    doAssert "proc sumNestedSequence*(values: seq[array[4, int]]): int" in
      generatedBindings
    doAssert "proc sumNestedArray*(values: array[4, seq[int]]): int" in generatedBindings
    doAssert "proc identityNode*(value: NativeAbi" in generatedBindings
    doAssert "children: seq[NativeAbi" in generatedBindings
    doAssert "proc sumBox*(value: NativeAbi" in generatedBindings
    doAssert "proc sumPair*(value: NativeAbi" in generatedBindings
    doAssert "proc sumNestedBox*(value: NativeAbi" in generatedBindings
    doAssert "proc identityRecursiveBox*(value: NativeAbi" in generatedBindings
    doAssert "key: int" in generatedBindings
    doAssert "value: bool" in generatedBindings
    doAssert "next: NativeAbi" in generatedBindings
    doAssert "proc identityPublicNode*(value: PublicNode): PublicNode" in
      generatedBindings
    doAssert "proc publicChildren*(value: PublicNode): seq[PublicNode]" in
      generatedBindings
    doAssert "next*: PublicNode" in generatedBindings
    doAssert "children*: seq[PublicNode]" in generatedBindings
    doAssert "root*: PublicNode" in generatedBindings
    doAssert "    x = 0" in generatedBindings
    doAssert "    y = 1" in generatedBindings
    doAssert "    z = 2" in generatedBindings
    doAssert "    w = 3" in generatedBindings
    doAssert "NativeAbit16_" notin generatedBindings
    doAssert "NativeAbit24_" notin generatedBindings

    let
      consumer = temporary / "consumer.nim"
      consumerCache = cache / "consumer"
      consumerBinary = temporary / "consumer".addFileExt(ExeExt)
    writeFile(
      consumer,
      """
import producer_abi

proc checkPublicRefs(node: PublicNode) {.used.} =
  let same: PublicNode = identityPublicNode(node)
  let children: seq[PublicNode] = publicChildren(same)
  let tree = identityPublicTree(PublicTree(root: same))
  let root: PublicNode = tree.root
  let next: PublicNode = root.next
  let nested: seq[PublicNode] = next.children
  discard children
  discard nested
""",
    )
    discard run(
      [
        compiler,
        "c",
        "--mm:orc",
        "-d:useMalloc",
        "--nimcache:" & consumerCache,
        "--path:" & temporary,
        "--out:" & consumerBinary,
        consumer,
      ]
    )
  else:
    echo "Skipping anonymous generic BIF test: current Nim lacks --genBif/nifler"
