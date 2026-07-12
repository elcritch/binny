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
