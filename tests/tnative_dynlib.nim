import std/[assertions, os, osproc, strutils, tempfiles]
import binny/native_dynlib
import binny/native_dynlib/[artifacts, model]
import binny/native_dynlib/staticlib

block bif_config_defaults_to_source_directory:
  let config =
    initBifNativeBindingsConfig("src/producer.nim", "build/cache", "libproducer.dylib")
  doAssert config.sourceRoot == "src"
  doAssert config.nimcacheDir == "build/cache"
  doAssert config.libraryName == "libproducer.dylib"

block bif_config_accepts_source_root:
  let config = initBifNativeBindingsConfig(
    "src/plugins/producer.nim", "build/cache", "libproducer.dylib", "src"
  )
  doAssert config.sourceRoot == "src"

block bif_config_adds_native_library_suffix:
  let config =
    initBifNativeBindingsConfig("src/producer.nim", "build/cache", "build/libproducer")
  when defined(windows):
    doAssert config.libraryName == "build/libproducer.dll"
  elif defined(macosx):
    doAssert config.libraryName == "build/libproducer.dylib"
  else:
    doAssert config.libraryName == "build/libproducer.so"

block bif_config_accepts_export_config:
  let
    exportConfig = initNativeExportConfig(
      [excludeProc("debug*")],
      includeProcs = [includeProc("public*")],
      typeImports = [importType("Rect", "bumpy")],
    )
    config = initBifNativeBindingsConfig(
      "src/producer.nim",
      "build/cache",
      "build/libproducer",
      exportConfig = exportConfig,
    )
  doAssert config.exportConfig.excludeProcs == exportConfig.excludeProcs
  doAssert config.exportConfig.includeProcs == exportConfig.includeProcs
  doAssert config.exportConfig.typeImports == exportConfig.typeImports
  doAssert config.exportConfig.typeImports[0].exported
  doAssert config.exportConfig.requireMatches

block native_export_selectors_match_exact_names_and_globs:
  let exact = excludeProc("foo=", source = "producer.nim")
  doAssert exact.matches("producer.nim", "foo=")
  doAssert not exact.matches("support.nim", "foo=")
  doAssert not exact.matches("producer.nim", "foo")

  let glob = excludeProc("ignored*Metric*", source = "src/*/producer*.nim")
  doAssert glob.matches("src/plugins/producer_test.nim", "ignoredMetric")
  doAssert glob.matches("src/plugins/producer.nim", "ignoredOldMetricValue")
  doAssert not glob.matches("src/producer.nim", "ignoredMetric")

  let everyProc = excludeProc("*")
  doAssert everyProc.matches("any/module.nim", "message")
  doAssert everyProc.matches("any/module.nim", "foo=")

  let included = includeProc("*", source = "bindings/*.nim")
  doAssert included.matches("bindings/native_bindings.nim", "render")
  doAssert not included.matches("support/native_bindings.nim", "render")

block native_export_config_loads_json:
  let (configFile, configPath) = createTempFile("binny-native-export-", ".json")
  defer:
    removeFile(configPath)
  configFile.write(
    """
{
  "includeProcs": [
    {"source": "bindings/*.nim", "name": "*"},
    {"source": "../support.nim", "name": "load*", "typeArgs": ["../backend.nim:State"]}
  ],
  "excludeProcs": [
    {"source": "producer*.nim", "name": "ignored*"},
    {"name": "foo="}
  ],
  "typeImports": [
    {"name": "Rect", "module": "bumpy", "export": false, "source": "../bumpy.nim"}
  ],
  "requireMatches": false
}
"""
  )
  configFile.close()

  let config = loadNativeExportConfig(configPath)
  doAssert config.includeProcs.len == 2
  doAssert config.excludeProcs.len == 2
  doAssert not config.requireMatches
  doAssert config.includeProcs[0].matches("bindings/producer.nim", "render")
  doAssert config.includeProcs[1].matches("../support.nim", "loadTypeface")
  doAssert config.includeProcs[1].typeArgs == @["../backend.nim:State"]
  doAssert config.excludeProcs[0].matches("producer.nim", "ignoredDebug")
  doAssert config.excludeProcs[1].matches("support.nim", "foo=")
  doAssert config.typeImports == [importType("Rect", "bumpy", exported = false,
    source = "../bumpy.nim")]

block native_export_config_rejects_invalid_type_imports:
  doAssert importType("Rect", "foo\\bar").module == "foo/bar"
  doAssertRaises NativeExportConfigError:
    discard initNativeExportConfig(typeImports = [importType("Rect", "")])
  doAssertRaises NativeExportConfigError:
    discard initNativeExportConfig(typeImports = [importType("Rect", "bumpy; discard")])
  doAssertRaises NativeExportConfigError:
    discard initNativeExportConfig(typeImports = [importType("Rect", "bumpy", source = "/bad")])

block native_export_config_rejects_backticks:
  doAssertRaises NativeExportConfigError:
    discard initNativeExportConfig([excludeProc("`foo=`")])

block manifest_binding_api_is_not_available:
  doAssert not compiles(initNativeBindingsConfig("producer.nim", "manifest.nif"))
  doAssert not compiles(generateNativeBindings("cache", "producer.nim", "manifest.nif"))

block native_initializer_combines_library_and_bif_identity:
  doAssert nativeInitSymbol("/tmp/libfoo-bar.so.3", "/cache/pro47-ngcy1.s.bif") ==
    "libfoo_bar_NimMain_pro47_ngcy1"

block generated_module_uses_configured_loader_name:
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

block generated_module_allows_strdefine_loader_name:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs: @[NativeProc(name: "ping", cSymbol: "ping")],
  )
  let generated = generateNativeModule(api, libraryNameStrdefine = true)
  doAssert "const nativeLibrary* {.strdefine.} = \"libsample.so\"" in generated

block generated_module_preserves_nil_type:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    procs: @[
      NativeProc(name: "clear", cSymbol: "clear", params: @[
        NativeParam(name: "value", typeSymbol: "`t5.208.window"),
      ]),
    ],
  )
  let generated = generateNativeModule(api)
  doAssert "proc clear*(value: typeof(nil))" in generated
  doAssert "value: pointer" notin generated

block windows_module_definition_exports_initializer_alias_and_public_symbols:
  let (exportFile, exportPath) = createTempFile("binny-native-exports-", ".def")
  exportFile.close()
  defer:
    removeFile(exportPath)
  writeWindowsModuleDefinition(
    exportPath,
    "sample.dll",
    "sample_NimMain_root",
    [
      NativeExportSymbol(cSymbol: "zeta"),
      NativeExportSymbol(cSymbol: "alpha"),
      NativeExportSymbol(cSymbol: "alpha"),
    ],
  )
  doAssert readFile(exportPath) ==
    "LIBRARY sample.dll\nEXPORTS\n" & "  sample_NimMain_root=NimMain\n  alpha\n  zeta\n"

block generated_module_requires_loader_name:
  let api = NativeApi(
    initSymbol: "NimMain", procs: @[NativeProc(name: "ping", cSymbol: "ping")]
  )
  doAssertRaises NativeArtifactError:
    discard generateNativeModule(api)

block generated_module_allows_an_initializer_only_api:
  let generated = generateNativeModule(
    NativeApi(libraryName: "libsample.so", initSymbol: "sample_NimMain_root")
  )
  doAssert "proc nativeNimMain()" in generated
  doAssert "nativeNimMain()" in generated
  doAssert "{.push nimcall, dynlib: nativeLibrary.}" in generated

block generated_module_checks_runtime_configuration:
  let temporary = createTempDir("binny-native-runtime-checks-", "")
  defer:
    removeDir(temporary)
  let source = temporary / "wrapper.nim"
  let buildMode =
    when defined(danger): " -d:danger"
    elif defined(release): " -d:release"
    else: ""
  let command = getCurrentCompilerExe().quoteShell &
    " check --noNimblePath --hints:off --warnings:off --nimcache:" &
    (temporary / "cache").quoteShell & buildMode
  for withLayout in [false, true]:
    var api = NativeApi(libraryName: "libsample.so", initSymbol: "NimMain")
    if withLayout:
      api.types = @[NativeType(
        name: "Value", nifSymbol: "Value.0.sample", kind: ntAlias,
        elementTypeSymbol: "int32", size: 4, alignment: 4,
      )]
    let generated = generateNativeModule(api)
    doAssert "static:\n  when not defined(useMalloc):" in generated
    doAssert "defined(gcArc) or defined(gcAtomicArc) or defined(gcOrc)" in generated
    writeFile(source, generated)
    for memoryManager in ["arc", "atomicArc", "orc"]:
      let flags = " --mm:" & memoryManager
      let accepted = execCmdEx(command & flags & " -d:useMalloc " & source.quoteShell)
      doAssert accepted.exitCode == 0, accepted.output
      let rejected = execCmdEx(command & flags & " --undef:useMalloc " & source.quoteShell)
      doAssert rejected.exitCode != 0, "wrapper must require useMalloc"
      doAssert "Binny native dynlib wrappers require -d:useMalloc." in rejected.output
    for memoryManager in ["refc", "none"]:
      let rejected = execCmdEx(command & " --mm:" & memoryManager &
        " -d:useMalloc " & source.quoteShell)
      doAssert rejected.exitCode != 0, "wrapper must require a supported memory manager"
      doAssert "Binny native dynlib wrappers require --mm:arc" in rejected.output

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

block generated_module_preserves_custom_range_bounds:
  let api = NativeApi(
    libraryName: "libsample.so", initSymbol: "NimMain",
    types: @[
      NativeType(
        name: "Small", nifSymbol: "Small.0.sample", typeId: "`t20.1.sample",
        kind: ntRange, elementTypeSymbol: "int16", rangeLow: "-4", rangeHigh: "6",
        size: 2, alignment: 2,
      ),
      NativeType(
        name: "NativeAbiRange", nifSymbol: "`t20.2.sample", typeId: "`t20.2.sample",
        kind: ntRange, elementTypeSymbol: "uint64",
        rangeLow: "9223372036854775808'u64", rangeHigh: "18446744073709551615'u64",
        size: 8, alignment: 8,
      ),
    ],
    procs: @[NativeProc(
      name: "bounds", cSymbol: "bounds", returnTypeSymbol: "Small.0.sample",
      params: @[NativeParam(name: "value", typeSymbol: "`t20.2.sample")],
    )],
  )
  let generated = generateNativeModule(api)
  doAssert "Small* = range[int16(-4)..int16(6)]" in generated
  doAssert ("value: range[uint64(9223372036854775808'u64).." &
    "uint64(18446744073709551615'u64)]") in generated
  doAssert "doAssert sizeof(Small) == 2" in generated
  doAssert "NativeAbiRange* =" notin generated

block generated_module_rejects_ranges_without_resolved_bounds:
  let api = NativeApi(
    libraryName: "libsample.so", initSymbol: "NimMain",
    types: @[NativeType(
      name: "MissingBounds", nifSymbol: "MissingBounds.0.sample", typeId: "`t20.1.sample",
      kind: ntRange, elementTypeSymbol: "int",
    )],
    procs: @[NativeProc(name: "consume", cSymbol: "consume")],
  )
  doAssertRaises NativeArtifactError:
    discard generateNativeModule(api)

block generated_array_indices_are_independent_of_discovery_order:
  for namedIndex in [false, true]:
    for lowerBound in [0, 2]:
      let indexSymbol = "`t20.1.sample"
      let sequenceSymbol = "`t24.1.sample"
      let arraySymbol = "`t16.1.sample"
      let indexType = NativeType(
        name: "Bounds", nifSymbol: (if namedIndex: "Bounds.0.sample" else: indexSymbol),
        typeId: indexSymbol, kind: ntRange, elementTypeSymbol: "int",
        rangeLow: $lowerBound, rangeHigh: $(lowerBound + 3), size: 8, alignment: 8,
      )
      let sequenceType = NativeType(
        name: "NativeAbiSequence", nifSymbol: sequenceSymbol, typeId: sequenceSymbol,
        kind: ntSequence, elementTypeSymbol: "int", size: 16, alignment: 8,
      )
      let arrayType = NativeType(
        name: "Values", nifSymbol: arraySymbol, typeId: arraySymbol, kind: ntArray,
        indexTypeSymbol: indexSymbol, elementTypeSymbol: sequenceSymbol,
        arrayLength: 4, size: 64, alignment: 8,
      )
      let expectedIndex =
        if namedIndex: "Bounds"
        elif lowerBound == 0: "4"
        else: "range[int(2)..int(5)]"
      var api = NativeApi(
        libraryName: "libsample.so", initSymbol: "NimMain",
        procs: @[NativeProc(
          name: "consume", cSymbol: "consume",
          params: @[NativeParam(name: "values", typeSymbol: arraySymbol)],
        )],
      )
      for types in [@[arrayType, sequenceType, indexType],
                    @[indexType, sequenceType, arrayType]]:
        api.types = types
        let generated = generateNativeModule(api)
        doAssert "values: array[" & expectedIndex & ", seq[int]]" in generated
      var namedArray = arrayType
      namedArray.nifSymbol = "Values.0.sample"
      api.types = @[namedArray, sequenceType, indexType]
      let generated = generateNativeModule(api)
      doAssert "Values* = array[" & expectedIndex & ", seq[int]]" in generated

block generated_module_preserves_sink_and_lent_contracts:
  let api = NativeApi(
    libraryName: "libsample.so", initSymbol: "NimMain",
    procs: @[
      NativeProc(
        name: "consume", cSymbol: "consume", returnTypeSymbol: "int",
        params: @[NativeParam(name: "value", typeSymbol: "string", bySink: true)],
      ),
      NativeProc(
        name: "borrow", cSymbol: "borrow", returnTypeSymbol: "string", returnByLent: true,
      ),
    ],
  )
  let generated = generateNativeModule(api)
  doAssert "proc consume*(value: sink string): int" in generated
  doAssert "proc borrow*(): lent string" in generated

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
          indexTypeSymbol: "DirectionCorners.0.sample",
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

block generated_module_resolves_nested_slices_before_containers:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types: @[
      NativeType(
        name: "Table",
        nifSymbol: "`t11.1.sample",
        typeId: "`t11.1.sample",
        kind: ntImportedGeneric,
        size: 40,
        alignment: 8,
        importModule: "std/tables",
        genericArguments: @["int", "`t11.3.sample"],
      ),
      NativeType(
        name: "NativeAbiSpans",
        nifSymbol: "`t24.2.sample",
        typeId: "`t24.2.sample",
        kind: ntSequence,
        elementTypeSymbol: "`t11.3.sample",
      ),
      NativeType(
        name: "HSlice",
        nifSymbol: "`t11.3.sample",
        typeId: "`t11.3.sample",
        kind: ntImportedGeneric,
        size: 16,
        alignment: 8,
        genericArguments: @["int", "int"],
      ),
    ],
    procs: @[
      NativeProc(
        name: "spans",
        cSymbol: "spans",
        returnTypeSymbol: "`t11.1.sample",
        params: @[NativeParam(name: "values", typeSymbol: "`t24.2.sample")],
      )
    ],
  )
  let generated = generateNativeModule(api)
  doAssert "values: seq[HSlice[int, int]]" in generated
  doAssert "): Table[int, HSlice[int, int]]" in generated
  doAssert "doAssert sizeof(HSlice[int, int]) == 16" in generated
  doAssert "doAssert alignof(HSlice[int, int]) == 8" in generated
  doAssert "HSlice* = object" notin generated

block generated_module_declares_case_enums_before_records:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types: @[
      NativeType(
        name: "Config",
        nifSymbol: "Config.0.sample",
        typeId: "`t17.1.sample",
        kind: ntObject,
        record: @[
          NativeRecordPart(
            kind: nrCase,
            discriminant: NativeField(
              name: "kind", typeSymbol: "Kind.0.sample", exported: true
            ),
            branches: @[NativeBranch(selectors: @["empty"], record: @[])],
          )
        ],
      ),
      NativeType(
        name: "Kind",
        nifSymbol: "Kind.0.sample",
        typeId: "`t14.2.sample",
        kind: ntEnum,
        enumValues: @[NativeEnumValue(name: "empty", ordinal: 0)],
      ),
    ],
    procs: @[NativeProc(name: "consume", cSymbol: "consume")],
  )
  let generated = generateNativeModule(api)
  doAssert generated.find("Kind* = enum") < generated.find("Config* = object")
  doAssert "case kind*: Kind\n    of empty:" in generated

block generated_module_reuses_imported_types:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "NimMain",
    types:
      @[
        NativeType(
          name: "Rect",
          nifSymbol: "Rect.0.bumpy",
          typeId: "`t20.1.bumpy",
          kind: ntObject,
          size: 16,
          alignment: 4,
          importModule: "bumpy",
          imported: true,
          exported: true,
          record:
            @[
              NativeRecordPart(
                kind: nrField,
                field: NativeField(
                  name: "x",
                  typeSymbol: "float32.0.system",
                  exported: true,
                  offset: 0,
                ),
              ),
              NativeRecordPart(
                kind: nrField,
                field: NativeField(
                  name: "y",
                  typeSymbol: "float32.0.system",
                  exported: true,
                  offset: 4,
                ),
              ),
              NativeRecordPart(
                kind: nrField,
                field: NativeField(
                  name: "w",
                  typeSymbol: "float32.0.system",
                  exported: true,
                  offset: 8,
                ),
              ),
              NativeRecordPart(
                kind: nrField,
                field: NativeField(
                  name: "h",
                  typeSymbol: "float32.0.system",
                  exported: true,
                  offset: 12,
                ),
              ),
            ],
        )
      ],
    procs:
      @[
        NativeProc(
          name: "identityRect",
          cSymbol: "identityRect",
          returnTypeSymbol: "Rect.0.bumpy",
          params: @[NativeParam(name: "value", typeSymbol: "Rect.0.bumpy")],
        )
      ],
  )
  let generated = generateNativeModule(api)
  doAssert "import bumpy" in generated
  doAssert "export bumpy.Rect" in generated
  doAssert "  Rect* = object" notin generated
  doAssert "proc identityRect*(value: Rect): Rect" in generated
  doAssert "doAssert sizeof(Rect) == 16" in generated
  doAssert "doAssert alignof(Rect) == 4" in generated
  doAssert "doAssert offsetOf(Rect, x) == 0" in generated
  doAssert "doAssert offsetOf(Rect, h) == 12" in generated

  var notExportedApi = api
  notExportedApi.types[0].exported = false
  let notExported = generateNativeModule(notExportedApi)
  doAssert "import bumpy" in notExported
  doAssert "export bumpy.Rect" notin notExported

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
  doAssert "proc add*(): int {.importc: \"add\", discardable.}" in generated

block generated_module_directly_imports_procs:
  let api = NativeApi(
    libraryName: "libsample.so",
    initSymbol: "libsample_NimMain_pro47ngcy1",
    procs: @[NativeProc(name: "ping", cSymbol: "ping")],
  )
  let generated = generateNativeModule(api)
  doAssert "{.push nimcall, dynlib: nativeLibrary.}" in generated
  doAssert "proc ping*() {.importc: \"ping\".}" in generated
  doAssert "initNativeLibrary" notin generated
  doAssert "proc nativeNimMain() {.cdecl, importc: " &
    "\"libsample_NimMain_pro47ngcy1\", dynlib: nativeLibrary.}" in generated
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
    types:
      @[
        NativeType(
          name: "type",
          nifSymbol: "type.0.sample",
          typeId: "`t99.0.sample",
          kind: ntAlias,
          elementTypeSymbol: "`t31.0.system",
          size: 8,
          alignment: 8,
        )
      ],
    procs:
      @[
        NativeProc(
          name: "foo=",
          cSymbol: "foo_eq",
          params:
            @[
              NativeParam(name: "item", typeSymbol: "type.0.sample", byVar: true),
              NativeParam(name: "value", typeSymbol: "`t31.0.system"),
            ],
        ),
        NativeProc(
          name: "for",
          cSymbol: "for",
          returnTypeSymbol: "`t31.0.system",
          params: @[NativeParam(name: "item", typeSymbol: "type.0.sample")],
        ),
        NativeProc(name: "not-safe", cSymbol: "not_safe"),
      ],
  )
  let generated = generateNativeModule(api)
  doAssert "  `type`* = int" in generated
  doAssert "proc `foo=`*(item: var `type`; value: int)" in generated
  doAssert "proc `for`*(item: `type`): int" in generated
  doAssert "proc `not-safe`*()" in generated
