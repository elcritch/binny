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
  and `NimMain`.

## Try it

Use a Nim 2.3.1 devel compiler that provides `--genBif`, `nim ic`, and `nifler`:

```sh
~/.local/share/grabnim/nim-devel/bin/nim consumer
```

That builds the library, generates `generated/producer_abi.nim`, compiles the
existing consumer, and runs it. Use `nim e2e` to also verify that the generated
move-only type cannot be copied.

The tasks build these artifacts:

```text
generated/producer_abi.nim       reconstructed native Nim bindings
nimcache/libproducer.private.a   original private-external symbols
nimcache/libproducer.a           selected symbols promoted
nimcache/libproducer.exports     exact BIF-derived Mach-O export names
nimcache/libproducer.dylib       final filtered dynamic library
nimcache/consumer/consumer       ordinary Nim consumer executable
```

Inspect the result with:

```sh
nm -gU nimcache/libproducer.dylib
```

The list contains the 20 public procedures from `producer.nim` and
`support.nim`, three custom ownership hooks required by public types, and
`NimMain`. Private procedures, generated default hooks, runtime helpers, and
all other archive symbols remain hidden.

## How the build works

The regular C pipeline eliminates unused public procedures before producing an
object file. The incremental backend gives us a useful interception point:

1. `nim ic --genBif:on` writes semantic `.s.bif` files and pre-merge `.c.nif`
   artifacts.
2. `tools/native_dynlib` reads each application BIF and selects exported runtime
   routines plus custom ownership hooks required by public types.
3. It matches the semantic symbol in BIF to the same symbol recorded on a
   `.c.nif` definition, obtaining the exact backend C name.
4. It marks those definitions as liveness roots and lets Nim rerun its normal
   dependency closure and C emission.
5. The generated objects are collected into `libproducer.private.a`.
6. The tool extracts that archive and clears Mach-O `N_PEXT` only on the matched
   public definitions, producing `libproducer.a`.
7. Clang force-loads the promoted archive and applies
   `libproducer.exports` while linking the dylib.
8. The binding generator reads procedure signatures and concrete type layouts
   from BIF, then uses `.c.nif` for the exact import names.
9. The consumer compiles against the generated Nim module and loads the dylib
   directly.

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
- Generated bindings cover the concrete types exercised here: objects, refs,
  inheritance, case and packed objects, aliases, sequences, `OrderedTable`,
  tuples, open arrays, and custom or forbidden ownership hooks.

The integration test in `tests/tnative_staticlib.nim` builds a fresh fixture,
generates bindings without `.abi.nif`, and runs a separate Nim consumer.
