# Binny

Binny provides tools for interacting with binaries including generating Nim native dynamic libraries. Additionally it supports ELF parsing tools and SFrame support.

Build native Nim dynamic libraries and strongly typed Nim bindings from compiler metadata—without C export shims or export pragmas.

Binny turns ordinary public Nim routines (`proc name*`) into a filtered native dynamic-library API. It reads semantic BIF to identify the public surface, matches those declarations to their exact backend symbols, and reconstructs the Nim types and ownership hooks needed by consumers.

The native-library workflow is experimental. The no-pragma archive promotion
supports 64-bit Mach-O on macOS, little-endian ELF64 on Linux and FreeBSD, and
64-bit PE/COFF on Windows with MinGW.

It requires a Nim devel compiler with `--genBif` and `nifler`.

Binny imports the compiler type definitions from the Nim installation used
to build it. This lets the BIF reader materialize serialized definitions as
Nim `PType` nodes and use the compiler's `sonsImpl` rules for arrays,
containers, and generic instances. The installation must include the
`compiler/` sources. Nim devel binary nightlies include these sources and
`nifler`; install one with `grabnim devel`, or use a Nim devel source checkout.

## Why try it?

- Keep Nim's `*` marker as the source of truth for the public API.
- Export native Nim routines without `exportc` or producer
  wrappers.
- Preserve objects, refs, inheritance, case objects, containers, and custom
  ownership hooks in generated bindings.
- Export only the BIF-selected procedures and required runtime entry points.
- Exclude public procedures with exact or `*`-glob source/name selectors.
- Reuse compatible third-party ABI types in generated bindings with layout checks.
- Give each library its own initializer name, such as
  `libproducer_NimMain_pro47ngcy1`.
- Use the original Nim implementations instead of generating forwarding code.

## Try the native dynlib example

With Nim devel available as `nim`:

```sh
cd examples/nim_native_dynlib
nim e2e
./consumer
```

The `e2e` task builds an ordinary Nim producer as a static library, derives its
public API from BIF, promotes only the selected symbols, links a dynamic library,
generates `generated/producer_abi.nim`, and compiles the consumer. The resulting
`./consumer` remains runnable afterward.

Public producer declarations remain ordinary Nim code:

```nim
proc message*(): string =
  "hello from the dynlib"

proc sumNumbers*(numbers: openArray[int]): int =
  for number in numbers:
    result += number
```

Both procedures are included in the generated API because they are public;
private implementation routines remain hidden. Consumer code imports the
generated Nim module and calls the producer with ordinary Nim syntax:

```nim
import generated/producer_abi

echo message()
```

See [the native dynlib example](examples/nim_native_dynlib/README.md) for the
artifact layout, symbol inspection command, supported types, and complete build
sequence.

## Add Binny to a project

Add Binny as an Atlas dependency:

```nim
requires "https://github.com/elcritch/binny"
```

Then resolve it:

```sh
atlas install
```

Import Binny's NimScript builder from `config.nims`, describe the producer, and
add a task:

```nim
import binny/native_dynlib/build

var nativeBuild = initNativeDynlibBuildConfig(
  "src/plugin.nim",
  "libplugin",
  buildRoot = "build/native",
  bindingsPath = "generated/plugin_abi.nim",
  exportConfigPath = "binny.native.json",
)
nativeBuild.nimArgs = @["--mm:orc", "-d:useMalloc"]

task nativeDynlib, "Build the native library and its Nim bindings":
  nativeBuild.buildNativeDynlibAndBindings()
```

Run it with `nim nativeDynlib`. Binny uses the normal `nim c` pipeline by
default, performs both compiler passes, builds and promotes the archive, links
and verifies the filtered dynamic library, then generates the consumer module.
Set `backend = "ic"` in the constructor to use `nim ic` instead.

The builder also runs `nim dump --dump.format:json` with the producer arguments
and records its `lib_paths`. Export selectors can therefore name dependency
sources with `$pkg/` paths relative to their Nim import roots, regardless of
whether those roots come from Atlas, Nimble, a local checkout, or explicit
`--path` options.

When `libraryName` has no extension, Binny appends `.dylib` on macOS, `.so`
on Linux and FreeBSD, or `.dll` on Windows. Call
`nativeBuild.stageNativeDynlib("bin")` to copy the
library and generate a matching binding module in a distribution directory.

### Propagate exceptions

When a selected procedure has inferred or explicit exception effects, Binny can
bridge its `CatchableError` across separate producer and consumer runtimes. Build
both sides with matching goto exceptions, ARC or atomic ARC, and the C allocator:

```nim
nativeBuild.nimArgs = @["--exceptions:goto", "--mm:arc", "-d:useMalloc"]
```

The generated binding enforces the same consumer settings. It calls the native
procedure, retrieves any pending producer exception through a library-specific
endpoint, and re-raises it in the consumer runtime, preserving typed handlers
and messages. Non-raising procedures remain direct imports.

The bridge works with Binny's normal C and incremental C backends. Raising
iterators are supported by the normal C backend; the incremental backend does
not currently export iterators. ORC, callback exceptions, `Defect`, and panics
are not supported. Producer and consumer must use the same Nim compiler and ABI
configuration.

Projects that prohibit exceptions in their dynamic-library API can enable:

```text
-d:features.binny.forbidExceptions
```

Binny then rejects selected procedures with non-empty or unknown resolved
exception effects and lists them in the build error. Procedures that are known
not to raise can state the contract explicitly with `{.raises: [].}`.

### Hide implementation types

An export configuration can keep graphics/backend records opaque without
recompiling their implementation in the consumer:

```json
{
  "opaqueTypes": [
    {"name": "Renderer", "source": "renderer.nim"},
    {"name": "PresentationTarget", "source": "backend.nim"}
  ]
}
```

The selected names remain public, but their fields and field-type dependencies
do not. Direct native calls still use the original ABI. Reference aliases share
ownership; value copies and destruction delegate to producer-generated hooks.
Private storage preserves scalar and managed-field calling conventions, and
producer size/alignment checks run when the consumer module initializes.

Opaque exports currently require the normal C backend, matching ARC/atomicARC
producer and consumer builds, and `-d:useMalloc`. Only plain, final records (or
references to them) are supported; variants, inheritance, packed/union records,
closure fields, and custom/forbidden hooks on the selected record are rejected.
ORC tracing and incremental-backend opaque exports are not supported yet.
Selectors must resolve to exactly one public type, cannot overlap `typeImports`,
and may use source globs to disambiguate dependencies. Generate bindings for
each producer platform/backend: private storage is not a cross-platform binary ABI.

## Other binary tooling

Binny also contains lower-level binary inspection and stack-walking work:

- ELF metadata and symbol parsing.
- DWARF parsing, call-frame information, line tables, and symbolization. This
  area is still a work in progress.
- SFrame types, encoding, decoding, and stack walking, with AMD64 and AArch64
  test coverage.
- Nim symbol demangling and tools for converting DWARF unwind data to SFrame.

These modules remain available under `binny/elfparser`, `binny/dwarf`,
`binny/sframe`, and `binny/demangler`.

## Build and test

Build the aggregate module and run the general test task with:

```sh
atlas install --feature:test
nim c binny.nim
nim test
```

The CI uses Nim devel to build the aggregate module, test native binding
generation, and run the native dynamic-library end-to-end workflow on both
Linux, macOS, and Windows.
