import std/[assertions, strutils]
import binny/native_dynlib
import binny/native_dynlib/[artifacts, model]

block config_defaults_to_manifest_directory:
  let config = initNativeBindingsConfig(
    "src/producer.nim", "build/libproducer.abi.nif")
  doAssert config.sourcePath == "src/producer.nim"
  doAssert config.manifestPath == "build/libproducer.abi.nif"
  doAssert config.nimcacheDir == "build"
  doAssert config.libraryOverride.len == 0

block config_uses_current_directory_for_bare_manifest_name:
  let config = initNativeBindingsConfig(
    "producer.nim", "libproducer.abi.nif")
  doAssert config.nimcacheDir == "."

block config_accepts_explicit_overrides:
  let config = initNativeBindingsConfig(
    "producer.nim", "manifest.nif", "cache", "/opt/lib/libproducer.so")
  doAssert config.nimcacheDir == "cache"
  doAssert config.libraryOverride == "/opt/lib/libproducer.so"

block individual_path_overload_remains_available:
  doAssert compiles(generateNativeBindings(
    "cache", "producer.nim", "libproducer.abi.nif"))
  doAssert compiles(generateNativeBindings(
    "cache", "producer.nim", "libproducer.abi.nif", "libproducer.so"))

block generated_module_uses_manifest_loader_name:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs: @[NativeProc(name: "ping", cSymbol: "ping")])
  let generated = generateNativeModule(api)
  doAssert "const nativeLibrary* = \"libsample.so\"" in generated
  doAssert "/tmp/" notin generated

block generated_module_accepts_library_override:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs: @[NativeProc(name: "ping", cSymbol: "ping")])
  let generated = generateNativeModule(api, "/opt/lib/libsample.so")
  doAssert "const nativeLibrary* = \"/opt/lib/libsample.so\"" in generated

block generated_module_requires_loader_name:
  let api = NativeApi(
    initSymbol: "NimMain",
    procs: @[NativeProc(name: "ping", cSymbol: "ping")])
  doAssertRaises NativeArtifactError:
    discard generateNativeModule(api)

block generated_module_preserves_builtin_range_types:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types: @[
      NativeType(
        name: "Natural",
        nifSymbol: "Natural.0.system",
        typeId: "`t20.1.system",
        kind: ntRange),
    ],
    procs: @[
      NativeProc(
        name: "insert",
        cSymbol: "insert",
        params: @[
          NativeParam(name: "position", typeSymbol: "`t20.1.system"),
        ]),
    ])
  let generated = generateNativeModule(api)
  doAssert "`position`: Natural" in generated
  doAssert "Natural* =" notin generated

block generated_module_preserves_discardable_procs:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs: @[
      NativeProc(
        name: "add",
        cSymbol: "add",
        returnTypeSymbol: "int.0.system",
        discardable: true),
    ])
  let generated = generateNativeModule(api)
  doAssert "proc `add`*(): int {.discardable.}" in generated

block generated_module_reconstructs_open_arrays:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs: @[
      NativeProc(
        name: "sumNumbers",
        cSymbol: "_ZN8producer10sumNumbersE9openArrayI3intE",
        returnTypeSymbol: "int.0.system",
        params: @[
          NativeParam(
            name: "numbers",
            typeSymbol: "openArray.0.system",
            lowering: nlPointer,
            hiddenLengthCount: 1),
        ]),
    ])
  let generated = generateNativeModule(api)
  doAssert "proc nativeRaw0(`numbers`: openArray[int]): int" in generated
  doAssert "proc `sumNumbers`*(`numbers`: openArray[int]): int" in generated
  doAssert "result = nativeRaw0(`numbers`)" in generated

block generated_module_reconstructs_named_open_array_elements:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types: @[
      NativeType(
        name: "NumberSpan",
        nifSymbol: "NumberSpan.0.producer",
        typeId: "`t17.1.producer",
        kind: ntObject,
        size: 8,
        alignment: 8),
    ],
    procs: @[
      NativeProc(
        name: "sumSpans",
        cSymbol:
          "_ZN8producer8sumSpansE3int9openArrayIN8producer10NumberSpanEE4bool",
        returnTypeSymbol: "int.0.system",
        params: @[
          NativeParam(name: "start", typeSymbol: "int.0.system"),
          NativeParam(
            name: "spans",
            typeSymbol: "openArray.0.system",
            lowering: nlPointer,
            hiddenLengthCount: 1),
          NativeParam(name: "enabled", typeSymbol: "bool.0.system"),
        ]),
    ])
  let generated = generateNativeModule(api)
  doAssert "`spans`: openArray[NumberSpan]" in generated
  doAssert "nativeRaw0(`start`, `spans`, `enabled`)" in generated
