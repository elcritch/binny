# Native Nim dylib without export pragmas

This experiment turns ordinary public Nim procedures into a native-ABI dynamic
library. The producer uses only normal `proc name*` declarations—there is no
`exportc`, `exportabi`, C wrapper, or generated producer shim.

Why this is useful:

- Nim's `*` remains the source of truth for the public API.
- Semantic BIF supplies public/private visibility.
- The incremental backend supplies the exact generated C symbol name.
- The original Nim bodies are retained and linked directly.
- The same BIF reconstructs strongly typed Nim consumer bindings.
- The final dylib exports the selected procedures, required ownership hooks,
  and a library-specific initializer such as
  `libproducer_NimMain_pro47ngcy1`.

## Try it

Use a Nim 2.3.1 devel compiler that provides `--genBif` and `nifler`:

```sh
~/.local/share/grabnim/nim-devel/bin/nim e2e
./consumer
```

That builds the library, generates `generated/producer_abi.nim`, compiles and
runs the existing consumer, and verifies that the generated move-only type
cannot be copied. The consumer remains available as `./consumer` afterward.
The example's `config.nims` uses `binny/native_dynlib/build`; projects only need
to provide their producer path, library name, compiler flags, and optional
export filter. The builder uses `nim c` by default. Set `backend = "ic"` to use
the incremental backend.

## Exclude public procedures

`native_dynlib.json` removes selected public procedures before they become
backend liveness roots:

```json
{
  "excludeProcs": [
    {"source": "producer*.nim", "name": "ignored*"},
    {"source": "support.nim", "name": "debugDump"}
  ],
  "requireMatches": true
}
```

Both `source` and `name` accept `*` as a zero-or-more-character wildcard. Source
paths are relative to the configured source root. Write quoted Nim names
without backticks, such as `foo=`, `for`, or `[]`. A selector applies to every
matching overload.

With `requireMatches` enabled—the default—a misspelled or stale selector stops
the build. Exclusions apply to ordinary public procedures; required ownership
hooks and the library initializer remain present. The example passes this same
file to the builder, which applies it to both archive rooting and binding
generation.

## Reuse imported ABI types

When a public procedure uses a type already provided by a dependency, add a
`typeImports` entry to the same JSON file:

```json
{
  "typeImports": [
    {"name": "Rect", "module": "bumpy"}
  ]
}
```

The generated binding imports the module and uses its `Rect` declaration
instead of reconstructing another one. Nested module paths such as `foo/bar`
are supported. The binding also emits compile-time `sizeof`, `alignof`, and
exported-field offset assertions against the producer's BIF layout, so an
incompatible local type fails when the consumer is compiled.
Imported types retain their identity inside standard-library generics, such as
`Option[Vec2]`, including compiler-generated aliases of the imported type.
The generated binding also re-exports each imported type, allowing a facade
module to expose those third-party types without importing and exporting each
dependency again. Re-exporting defaults to enabled for each entry. To keep one
imported type private, set its `export` field to `false`:

```json
{
  "typeImports": [
    {"name": "Rect", "module": "bumpy", "export": false}
  ]
}
```

Concrete generic routines are selected through their public declaration's
source/name, just like ordinary routines. Binny follows the compiler's
`instantiatedFrom` and generic `offer` records; it exports every concrete
specialization in the active producer import graph, not generic declarations
or instances left by inactive builds. The producer must instantiate the desired
specializations. C builds generate callable forwarding thunks automatically,
including for generic inline routines.

Use optional `typeArgs` to select an exact specialization. Builtin arguments use
their Nim spelling; named arguments use `source.nim:Type`, relative to the
configured producer source root. Arguments do not accept globs. For example,
with FigDraw's `src/figdraw/bindings` as the source root:

```json
{
  "includeProcs": [
    {"source": "../figrender.nim", "name": "backendKind",
     "typeArgs": ["../windowing/siwinshim.nim:SiwinRenderBackend"]},
    {"source": "../figrender.nim", "name": "setText*",
     "typeArgs": ["../windowing/siwinshim.nim:SiwinRenderBackend"]}
  ],
  "typeImports": [
    {"name": "CAMetalLayer", "module": "metalx/cametal",
     "source": "*metalx/src/metalx/cametal.nim"},
    {"name": "Lock", "module": "std/locks"},
    {"name": "Cond", "module": "std/locks"},
    {"name": "NSView", "module": "darwin/app_kit/nsview",
     "source": "*darwin/darwin/app_kit/nsview.nim"}
  ]
}
```

The optional `typeImports.source` identifies the producer declaration's module,
independently of the consumer's `module` import path. It uses the same relative
path/glob rules as routine selection. Omitting it retains strict name ambiguity
checks. Same-named imported types are qualified in signatures and layout checks;
dependency aliases follow exact BIF targets, while `distinct` types stay distinct.
Selected specializations that erase to indistinguishable parameter signatures
are rejected with a request to select `typeArgs`, rather than choosing one.

The non-graphical macOS integration probe uses actual FigDraw renderer types and
all seven backend/text-flag routines without opening a window or creating a GPU
context. It writes only into Binny's `.nimcache/figdraw-renderer-probe`:

```sh
/path/to/Nim/bin/nim c -r --path:. tools/probe_figdraw_renderer.nim /path/to/figdraw
```

The workflow uses and builds these files:

```text
generated/producer_abi.nim         reconstructed native Nim bindings
native_dynlib.json                 public-procedure exclusion config
nimcache/c/libproducer.private.a   original hidden/private symbols
nimcache/c/libproducer.a           selected symbols promoted
nimcache/c/libproducer.exports     BIF-derived linker export control
nimcache/c/libproducer.so          filtered library on Linux and FreeBSD
nimcache/c/libproducer.dylib       filtered library on macOS
consumer                           ordinary Nim consumer executable
```

Inspect the result on Linux or FreeBSD with:

```sh
nm -D --defined-only nimcache/c/libproducer.so
```

Or on macOS with:

```sh
nm -gU nimcache/c/libproducer.dylib
```

The list contains the 20 public procedures from `producer.nim` and
`support.nim`, three custom ownership hooks required by public types, and
one library-specific `NimMain` alias. Private procedures, the original
`NimMain` name, generated default hooks, runtime helpers, and all other archive
symbols remain hidden.

## How the build works

Binny supports both the regular C and incremental compiler backends. The
regular C backend is the default:

1. `nim c --genBif:on` (or `nim ic --genBif:on`) writes semantic `.s.bif`
   files and backend `.c` (or `.c.nif`) artifacts.
2. `tools/native_dynlib` reads each application BIF, applies
   `native_dynlib.json`, and selects the remaining exported routines plus custom
   ownership hooks required by public types.
3. Incremental builds match semantic symbols to `.c.nif` definitions. Regular
   C builds use only function definitions in translation units listed by the
   compiler's active JSON link manifest, with source-aware module ownership.
   Declarations and stale artifacts cannot supply export names.
4. It makes those definitions liveness roots and reruns Nim's normal dependency
   closure and C emission. With `nim c`, Binny generates a temporary root
   module; with `nim ic`, it updates the backend roots directly. The C root
   imports the original producer even for dependency-only exports, and emits
   out-of-line thunks for selected inline routines.
5. On Linux and FreeBSD, the emitted C is recompiled as position-independent
   code before the generated objects are collected into
   `libproducer.private.a`.
6. The tool extracts that archive and promotes only matched public definitions:
   it clears Mach-O `N_PEXT` on macOS or changes ELF visibility from hidden to
   default on Linux and FreeBSD.
7. The host linker aliases `NimMain` to a name made from the library name and
   root BIF identity, force-loads the promoted archive, and applies
   `libproducer.exports` as a Darwin export list or GNU version script. Only
   the unique alias is public.
8. The binding generator reads procedure signatures and concrete type layouts
   from BIF, then uses the same active backend artifacts for exact import names.
9. The consumer compiles against the generated Nim module and loads the dynamic
   library directly.

This keeps both policy decisions outside the compiler: BIF decides which Nim
declarations are public, and the platform export list decides which native
symbols the dylib exposes.

## Current boundaries

- Archive promotion supports 64-bit Mach-O on macOS and little-endian ELF64 on
  Linux and FreeBSD.
- The producer and caller must agree on Nim compiler, memory manager, allocator,
  target, and native type layouts. Generated wrappers require `-d:useMalloc` and
  `--mm:arc`, `--mm:atomicArc`, or `--mm:orc` at compile time, even without layout
  checks. These guards do not prove that the producer used matching settings.
- Application modules are the BIF modules whose source files live beside the
  main producer source. Compiler and dependency modules are excluded.
- A selected routine must have one externally linked backend definition. Open
  generics and imported declarations are not promoted. Selected inline routines
  in regular C builds use automatically generated callable thunks; local symbols
  are never force-promoted.
- Generated bindings cover the concrete types exercised here: objects, refs,
  inheritance, case and packed objects, aliases, sequences, `Table`,
  `OrderedTable`, `CountTable`, their `Ref` variants, `HashSet`, `OrderedSet`,
  `Deque`, `Option`, `Slice`, `HSlice`, tuples, open arrays, custom ranges,
  typed pointers, `UncheckedArray`, and custom or forbidden ownership hooks.

Selected public methods export Nim's dispatcher, so a consumer call reaches
the producer's runtime-specific override rather than calling only the base
implementation. Standard-library container instances reuse their local Nim
declarations; their concrete argument types are reconstructed as needed.
`Slice[T]` uses the canonical `HSlice[T, T]` declaration, including in procedure
signatures and nested containers. Backwards bounds such as `1 .. ^2` retain
Nim's `BackwardsIndex` type. No `typeImports` configuration is needed for slices.

Sets, tables, and deques also reuse their standard-library declarations without
`typeImports` entries, including instances appearing only in routine signatures
or nested inside other containers.

Range bindings preserve the resolved bounds and base type, including signed and
unsigned integers, chars, enums, and floats. Typed buffers retain their
`ptr UncheckedArray[T]` element type; pointers remain borrowed raw storage, so the
caller must provide valid storage for the duration of each call.

Generated signatures preserve `sink` parameters and `lent` returns, including
callback types. Sink arguments follow Nim's usual move-or-copy rules; lent
results borrow storage whose owner must remain alive.

Reconstructed dependency types do not require importing their original module
into the consumer. Polymorphic refs must be constructed by the producer to
retain the runtime type information used by its dispatcher.

The integration test in `tests/tnative_staticlib.nim` builds a fresh fixture,
generates bindings from BIF and C NIF, and runs a separate Nim consumer.
`tests/tnative_dynlib_methods.nim` checks dispatch, container fields, callbacks,
and dependency-free consumer bindings with both compiler backends.
`tests/tnative_dynlib_coretypes.nim` covers container reuse, range checks, typed
buffers, and sink/lent ownership behavior with both backends under ARC and ORC.
`tests/tnative_dynlib_c_exports.nim` covers clean two-pass C builds, stale
artifacts, same-named modules, overloads, inline calls, and dependency-only
producer initialization under ARC with `useMalloc`.

The build helper records its exact C manifest automatically. When calling
`prepareNativeRoutines` directly with multiple build descriptions in one cache,
pass `cBuildManifest = "path/to/backend.json"` (or use the tool's
`--c-build-manifest:...` option). Binny does not select a manifest by timestamp.
