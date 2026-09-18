import std/[assertions, json, os, osproc, sequtils, strutils, tempfiles]

proc command(arguments: openArray[string]): string =
  result = arguments.mapIt(it.quoteShell).join(" ")

proc run(arguments: openArray[string]): string =
  let value = execCmdEx(command(arguments))
  doAssert value.exitCode == 0, command(arguments) & "\n" & value.output
  result = value.output

let compiler = getCurrentCompilerExe()
let help = execCmdEx(compiler.quoteShell & " --fullhelp")
if help.exitCode == 0 and "--genBif:on|off" in help.output and
    fileExists(compiler.parentDir / ("nifler" & ExeExt)):
  for (backend, memoryManager) in [("c", "arc"), ("c", "atomicArc"), ("ic", "arc")]:
    let temporary = createTempDir(
      "binny-native-exceptions-" & backend & "-" & memoryManager & "-", ""
    )
    var completed = false
    defer:
      if completed:
        removeDir(temporary)
      else:
        echo "Exception bridge fixture retained at ", temporary
    copyDir(currentSourcePath.parentDir / "fixtures/native_dynlib_exceptions", temporary)
    writeFile(
      temporary / "nim.cfg",
      "--path:" & currentSourcePath.parentDir.parentDir.escape & "\n",
    )

    let
      producer = temporary / "application/producer.nim"
      bindings = temporary / "exceptions_abi.nim"
      consumer = temporary / "consumer.nim"
      buildArguments = @[
        compiler, "exceptions", "--path:" & currentSourcePath.parentDir.parentDir,
      ] & (if memoryManager == "atomicArc": @["-d:exceptionAtomicArc"] else: @[]) &
        (if backend == "ic": @["-d:exceptionIncremental"] else: @[]) &
        @[producer]
    discard run(buildArguments)

    let
      externalRoot = temporary / "external-packages/arbitrary-layout/src"
      compilerPaths = parseFile(
        temporary / "cache" / backend / "producer/binny_nim_paths.json"
      )["lib_paths"].getElems.mapIt(it.getStr)
    doAssert expandFilename(externalRoot) in compilerPaths

    let generated = readFile(bindings)
    doAssert "proc binnyTakePendingException" in generated
    doAssert "proc binnyCheckPendingException" in generated
    doAssert "recompile with --exceptions:goto" in generated
    doAssert "proc failValue*" in generated
    doAssert "proc doubleValue*" in generated
    doAssert "proc doubleValue*(value: int): int {.importc:" in generated
    doAssert "proc externalDouble*" in generated
    doAssert "proc identityValue*" in generated
    doAssert "import portable/types" in generated
    if backend == "c":
      doAssert "iterator valuesThenFail*" in generated

    let consumerArguments = @[
      compiler,
      "c",
      "-r",
      "--exceptions:goto",
      "--mm:" & memoryManager,
      "-d:useMalloc",
      "--noNimblePath",
      "--path:" & currentSourcePath.parentDir.parentDir,
      "--path:" & temporary,
      "--path:" & externalRoot,
      "--nimcache:" & temporary / "consumer-cache",
      "--out:" & temporary / "consumer",
      consumer,
    ]
    discard run(consumerArguments)

    var wrongModeArguments = consumerArguments.filterIt(it != "-r")
    for argument in wrongModeArguments.mitems:
      if argument == "--exceptions:goto":
        argument = "--exceptions:setjmp"
    let wrongMode = execCmdEx(command(wrongModeArguments))
    doAssert wrongMode.exitCode != 0
    doAssert "recompile with --exceptions:goto" in wrongMode.output

    var orcArguments = consumerArguments.filterIt(it != "-r")
    for argument in orcArguments.mitems:
      if argument == "--mm:" & memoryManager:
        argument = "--mm:orc"
    let orc = execCmdEx(command(orcArguments))
    doAssert orc.exitCode != 0
    doAssert "ORC is not supported" in orc.output

    let forbidden = execCmdEx(command(
      @[
        compiler, "exceptions", "--path:" & currentSourcePath.parentDir.parentDir,
        "-d:features.binny.forbidExceptions",
      ] & (if backend == "ic": @["-d:exceptionIncremental"] else: @[]) & @[producer]
    ))
    doAssert forbidden.exitCode != 0
    doAssert "forbids exceptions" in forbidden.output

    let wrongProducerMode = execCmdEx(command(
      @[
        compiler, "exceptions", "--path:" & currentSourcePath.parentDir.parentDir,
        "-d:exceptionWrongMode",
      ] & (if backend == "ic": @["-d:exceptionIncremental"] else: @[]) & @[producer]
    ))
    doAssert wrongProducerMode.exitCode != 0
    doAssert "require --exceptions:goto" in wrongProducerMode.output

    completed = true
else:
  echo "Skipping native exception bridge test: compiler lacks BIF support"
