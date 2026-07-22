# Native Nim dylib without export pragmas

This experiment turns ordinary public Nim procedures into a native-ABI dynamic
library. The producer uses only normal `proc name*` declarations—there is no
`exportc`, `exportabi`, C wrapper, or generated producer shim.

Why this is useful:

- Nim's `*` remains the source of truth for the public API.
- Semantic BIF supplies public/private visibility.
- The incremental backend supplies the exact generated C symbol name.
- The original Nim bodies are retained and linked directly.
- The final dylib exports only the selected Nim procedures and `NimMain`.

## Try it

Use a Nim 2.3.1 devel compiler that provides `--genBif`, `nim ic`, and `nifler`:

```sh
~/.local/share/grabnim/nim-devel/bin/nim e2e
```

The task builds these artifacts under `nimcache/`:

```text
libproducer.private.a  original archive with private-external Nim symbols
libproducer.a          rebuilt archive with public procedures promoted
libproducer.exports    exact BIF-derived Mach-O export names
libproducer.dylib      final filtered dynamic library
```

Inspect the result with:

```sh
nm -gU nimcache/libproducer.dylib
```

The list contains the 20 public procedures from `producer.nim` and
`support.nim`, plus `NimMain`. Private procedures, runtime helpers, and all
other archive symbols remain hidden.

## How the build works

The regular C pipeline eliminates unused public procedures before producing an
object file. The incremental backend gives us a useful interception point:

1. `nim ic --genBif:on` writes semantic `.s.bif` files and pre-merge `.c.nif`
   artifacts.
2. `tools/native_dynlib` reads each application BIF and selects exported runtime
   routines owned by that module.
3. It matches the semantic symbol in BIF to the same symbol recorded on a
   `.c.nif` definition, obtaining the exact backend C name.
4. It marks those definitions as liveness roots and lets Nim rerun its normal
   dependency closure and C emission.
5. The generated objects are collected into `libproducer.private.a`.
6. The tool extracts that archive and clears Mach-O `N_PEXT` only on the matched
   public definitions, producing `libproducer.a`.
7. Clang force-loads the promoted archive and applies
   `libproducer.exports` while linking the dylib.

This keeps both policy decisions outside the compiler: BIF decides which Nim
declarations are public, and the platform export list decides which native
symbols the dylib exposes.

## Current boundaries

- Archive promotion currently supports 64-bit Mach-O on macOS.
- The producer and caller must agree on Nim compiler, memory manager, allocator,
  target, and native type layouts.
- Application modules are the BIF modules whose source files live beside the
  main producer source. Compiler and dependency modules are excluded.
- A selected routine must have one externally linked backend definition. Open
  generics, imported declarations, and local-only inline definitions are not
  promoted.
- This round builds and validates the library export surface. Regenerating the
  higher-level consumer bindings without the old `.abi.nif` manifest is separate
  work.

The integration test in `tests/tnative_staticlib.nim` also loads the resulting
dylib, calls `NimMain`, and invokes a promoted `nimcall` procedure.
