import std/[assertions, os, osproc, strformat, strutils]
import binny/native_dynlib
import binny/native_dynlib/[artifacts, model]

const NativeDependencyFixtureSource = "tests/fixtures/native_dynlib_hidden_dependency.nim"
const NativeDependencyFixtureCacheDir = "tests/.nimcache_hidden_dependency"
const NativeDependencyLibrary = "libnative_dynlib_hidden_dependency"

func nativeDependencyLibraryExt(): string =
  when defined(windows):
    "dll"
  elif defined(macosx):
    "dylib"
  else:
    "so"

proc nativeDependencyFixturePaths():
    tuple[cacheDir: string, sourcePath: string, manifestPath: string] =
  let
    rootDir = getCurrentDir()
    cacheDir = rootDir / NativeDependencyFixtureCacheDir
    sourcePath = rootDir / NativeDependencyFixtureSource
    manifestPath = cacheDir / (NativeDependencyLibrary & ".abi.nif")
  (cacheDir, sourcePath, manifestPath)

proc ensureNativeDependencyFixtureArtifacts(paths: tuple[
    cacheDir: string, sourcePath: string, manifestPath: string
  ]): bool =
  createDir(paths.cacheDir)
  let libraryPath = paths.cacheDir / (NativeDependencyLibrary & "." & nativeDependencyLibraryExt())
  if fileExists(paths.manifestPath):
    return true
  let compileCommand = fmt(
    "{getCurrentCompilerExe()} c --experimental:abi --emitBif:on --app:lib" &
      " --nimcache:{paths.cacheDir} --out:{libraryPath} {paths.sourcePath}"
  )
  let compiled = execCmdEx(compileCommand)
  if compiled.exitCode == 0:
    return true
  if "unknown experimental feature" in compiled.output:
    return false
  doAssert false, "failed to compile hidden dependency fixture: " & compiled.output

proc hasNativeDependencyFixtureArtifacts(paths: tuple[
    cacheDir: string, sourcePath: string, manifestPath: string
  ]): bool =
  ensureNativeDependencyFixtureArtifacts(paths)

block config_defaults_to_manifest_directory:
  let config = initNativeBindingsConfig("src/producer.nim", "build/libproducer.abi.nif")
  doAssert config.sourcePath == "src/producer.nim"
  doAssert config.manifestPath == "build/libproducer.abi.nif"
  doAssert config.nimcacheDir == "build"
  doAssert config.libraryOverride.len == 0

block config_uses_current_directory_for_bare_manifest_name:
  let config = initNativeBindingsConfig("producer.nim", "libproducer.abi.nif")
  doAssert config.nimcacheDir == "."

block config_accepts_explicit_overrides:
  let config = initNativeBindingsConfig(
    "producer.nim", "manifest.nif", "cache", "/opt/lib/libproducer.so"
  )
  doAssert config.nimcacheDir == "cache"
  doAssert config.libraryOverride == "/opt/lib/libproducer.so"

block individual_path_overload_remains_available:
  doAssert compiles(
    generateNativeBindings("cache", "producer.nim", "libproducer.abi.nif")
  )
  doAssert compiles(
    generateNativeBindings(
      "cache", "producer.nim", "libproducer.abi.nif", "libproducer.so"
    )
  )

block generated_module_uses_manifest_loader_name:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs: @[NativeProc(name: "ping", cSymbol: "ping")],
  )
  let generated = generateNativeModule(api)
  doAssert "const nativeLibrary* = \"libsample.so\"" in generated
  doAssert "/tmp/" notin generated

block generated_module_accepts_library_override:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs: @[NativeProc(name: "ping", cSymbol: "ping")],
  )
  let generated = generateNativeModule(api, "/opt/lib/libsample.so")
  doAssert "const nativeLibrary* = \"/opt/lib/libsample.so\"" in generated

block generated_module_requires_loader_name:
  let api = NativeApi(
    initSymbol: "NimMain", procs: @[NativeProc(name: "ping", cSymbol: "ping")]
  )
  doAssertRaises NativeArtifactError:
    discard generateNativeModule(api)

block generated_module_preserves_builtin_range_types:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types:
      @[
        NativeType(
          name: "Natural",
          nifSymbol: "Natural.0.system",
          typeId: "`t20.1.system",
          kind: ntRange,
        )
      ],
    procs:
      @[
        NativeProc(
          name: "insert",
          cSymbol: "insert",
          params: @[NativeParam(name: "position", typeSymbol: "`t20.1.system")],
        )
      ],
  )
  let generated = generateNativeModule(api)
  doAssert "position: Natural" in generated
  doAssert "Natural* =" notin generated

block generated_module_preserves_exported_aliases:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types:
      @[
        NativeType(
          name: "ZLevel",
          nifSymbol: "ZLevel.0.sample",
          typeId: "`t32.1.sample",
          kind: ntAlias,
          elementTypeSymbol: "int8.0.system",
          size: 1,
          alignment: 1,
        )
      ],
    procs:
      @[
        NativeProc(
          name: "layer",
          cSymbol: "layer",
          returnTypeSymbol: "ZLevel.0.sample",
          params: @[NativeParam(name: "level", typeSymbol: "`t32.1.sample")],
        )
      ],
  )
  let generated = generateNativeModule(api)
  doAssert "ZLevel* = int8" in generated
  doAssert "proc layer*(level: ZLevel): ZLevel" in generated

block generated_module_preserves_array_index_types:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types:
      @[
        NativeType(
          name: "DirectionCorners",
          nifSymbol: "DirectionCorners.0.sample",
          typeId: "`t10.1.sample",
          kind: ntEnum,
          size: 1,
          alignment: 1,
        ),
        NativeType(
          name: "CornerRadii",
          nifSymbol: "CornerRadii.0.sample",
          typeId: "`t16.1.sample",
          kind: ntArray,
          indexTypeSymbol: "DirectionCorners",
          elementTypeSymbol: "uint16.0.system",
          size: 8,
          alignment: 2,
        ),
      ],
    procs: @[NativeProc(name: "consume", cSymbol: "consume")],
  )
  let generated = generateNativeModule(api)
  doAssert "CornerRadii* = array[DirectionCorners, uint16]" in generated

block generated_module_imports_canonical_ordered_tables:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types:
      @[
        NativeType(
          name: "Layer",
          nifSymbol: "Layer.0.sample",
          typeId: "`t32.1.sample",
          kind: ntAlias,
          elementTypeSymbol: "int8.0.system",
        ),
        NativeType(
          name: "RenderList",
          nifSymbol: "RenderList.0.sample",
          typeId: "`t24.2.sample",
          kind: ntSequence,
          elementTypeSymbol: "string.0.system",
        ),
        NativeType(
          name: "OrderedTable",
          nifSymbol: "`t11.3.sample",
          typeId: "`t11.3.sample",
          kind: ntImportedGeneric,
          size: 40,
          alignment: 8,
          importModule: "std/tables",
          genericArguments: @["Layer.0.sample", "RenderList.0.sample"],
        ),
        NativeType(
          name: "Renders",
          nifSymbol: "Renders.0.sample",
          typeId: "`t22.4.sample",
          kind: ntRefObject,
          size: 8,
          alignment: 8,
          record:
            @[
              NativeRecordPart(
                kind: nrField,
                field: NativeField(
                  name: "layers", typeSymbol: "`t11.3.sample", exported: true
                ),
              )
            ],
        ),
      ],
    procs: @[NativeProc(name: "consume", cSymbol: "consume")],
  )
  let generated = generateNativeModule(api)
  doAssert "import std/tables" in generated
  doAssert "layers*: OrderedTable[Layer, RenderList]" in generated
  doAssert "doAssert sizeof(OrderedTable[Layer, RenderList]) == 40" in generated
  doAssert "OrderedTable* = object" notin generated

block generated_module_preserves_discardable_procs:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs:
      @[
        NativeProc(
          name: "add",
          cSymbol: "add",
          returnTypeSymbol: "int.0.system",
          discardable: true,
        )
      ],
  )
  let generated = generateNativeModule(api)
  doAssert "proc add*(): int {.importc: \"add\", discardable.}" in
    generated

block generated_module_directly_imports_procs:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs: @[NativeProc(name: "ping", cSymbol: "ping")],
  )
  let generated = generateNativeModule(api)
  doAssert "{.push nimcall, dynlib: nativeLibrary.}" in generated
  doAssert "proc ping*() {.importc: \"ping\".}" in
    generated
  doAssert "initNativeLibrary" notin generated
  doAssert "proc nativeNimMain() {.cdecl, importc: \"NimMain\", dynlib: nativeLibrary.}" in
    generated
  doAssert "nativeNimMain()\n\n{.push nimcall, dynlib: nativeLibrary.}" in generated
  doAssert "{.pop.}" in generated
  doAssert "nativeRaw" notin generated

block generated_module_reconstructs_open_arrays:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs:
      @[
        NativeProc(
          name: "sumNumbers",
          cSymbol: "_ZN8producer10sumNumbersE9openArrayI3intE",
          returnTypeSymbol: "int.0.system",
          params:
            @[
              NativeParam(
                name: "numbers",
                typeSymbol: "openArray.0.system",
                lowering: nlPointer,
                hiddenLengthCount: 1,
              )
            ],
        )
      ],
  )
  let generated = generateNativeModule(api)
  doAssert "proc sumNumbers*(numbers: openArray[int]): int {.importc" in generated

block generated_module_reconstructs_named_open_array_elements:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types:
      @[
        NativeType(
          name: "NumberSpan",
          nifSymbol: "NumberSpan.0.producer",
          typeId: "`t17.1.producer",
          kind: ntObject,
          size: 8,
          alignment: 8,
        )
      ],
    procs:
      @[
        NativeProc(
          name: "sumSpans",
          cSymbol: "_ZN8producer8sumSpansE3int9openArrayIN8producer10NumberSpanEE4bool",
          returnTypeSymbol: "int.0.system",
          params:
            @[
              NativeParam(name: "start", typeSymbol: "int.0.system"),
              NativeParam(
                name: "spans",
                typeSymbol: "openArray.0.system",
                lowering: nlPointer,
                hiddenLengthCount: 1,
              ),
              NativeParam(name: "enabled", typeSymbol: "bool.0.system"),
            ],
        )
      ],
  )
  let generated = generateNativeModule(api)
  doAssert "spans: openArray[NumberSpan]" in generated

block generated_module_reconstructs_open_arrays_of_tuples:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types:
      @[
        NativeType(
          name: "NumberSpan",
          nifSymbol: "NumberSpan.0.producer",
          typeId: "`t17.1.producer",
          kind: ntObject,
          size: 8,
          alignment: 8,
        )
      ],
    procs:
      @[
        NativeProc(
          name: "sumLabeledSpans",
          cSymbol:
            "_ZN8producer15sumLabeledSpansE9openArrayI5tupleIN8producer10NumberSpanE6stringEE",
          returnTypeSymbol: "int.0.system",
          params:
            @[
              NativeParam(
                name: "spans",
                typeSymbol: "openArray.0.system",
                lowering: nlPointer,
                hiddenLengthCount: 1,
              )
            ],
        )
      ],
  )
  let generated = generateNativeModule(api)
  doAssert "spans: openArray[(NumberSpan, string)]" in generated

block generated_module_resolves_vmath_instantiations_to_public_aliases:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types:
      @[
        NativeType(
          name: "Rune",
          nifSymbol: "Rune.0.unicode",
          typeId: "`t12.1.unicode",
          kind: ntDistinct,
          elementTypeSymbol: "int32.0.system",
          size: 4,
          alignment: 4,
        ),
        NativeType(
          name: "Vec2",
          nifSymbol: "Vec2.0.vmath",
          typeId: "`t17.1.vmath",
          kind: ntObject,
          size: 8,
          alignment: 4,
        ),
      ],
    procs:
      @[
        NativeProc(
          name: "place",
          cSymbol: "_ZN8producer5placeE9openArrayI5tupleI4Rune5GVec2I7float32EEE",
          params:
            @[
              NativeParam(
                name: "glyphs",
                typeSymbol: "openArray.0.system",
                lowering: nlPointer,
                hiddenLengthCount: 1,
              )
            ],
        )
      ],
  )
  let generated = generateNativeModule(api)
  doAssert "glyphs: openArray[(Rune, Vec2)]" in generated

block generated_module_escapes_unsafe_identifiers:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs: @[
      NativeProc(name: "for", cSymbol: "for"),
      NativeProc(name: "not-safe", cSymbol: "not_safe"),
    ],
  )
  let generated = generateNativeModule(api)
  doAssert "proc `for`*()" in generated
  doAssert "proc `not-safe`*()" in generated

block read_native_bindings_collects_dependent_hidden_type:
  let paths = nativeDependencyFixturePaths()
  if hasNativeDependencyFixtureArtifacts(paths):
    let generated = generateNativeBindings(paths.cacheDir, paths.sourcePath, paths.manifestPath)
    doAssert "PublicBox* = object" in generated
    doAssert "= seq[int]" in generated
