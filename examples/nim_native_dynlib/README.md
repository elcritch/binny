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

Use a Nim 2.3.1 devel compiler that provides `--genBif`, `nim ic`, and `nifler`:

```sh
~/.local/share/grabnim/nim-devel/bin/nim e2e
./consumer
```

That builds the library, generates `generated/producer_abi.nim`, compiles and
runs the existing consumer, and verifies that the generated move-only type
cannot be copied. The consumer remains available as `./consumer` afterward.

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
file to both the archive-rooting tool and binding generator.

The workflow uses and builds these files:

```text
generated/producer_abi.nim       reconstructed native Nim bindings
native_dynlib.json               public-procedure exclusion config
nimcache/libproducer.private.a   original hidden/private symbols
nimcache/libproducer.a           selected symbols promoted
nimcache/libproducer.exports     BIF-derived linker export control
nimcache/libproducer.so          filtered library on Linux and FreeBSD
nimcache/libproducer.dylib       filtered library on macOS
consumer                         ordinary Nim consumer executable
```

Inspect the result on Linux or FreeBSD with:

```sh
nm -D --defined-only nimcache/libproducer.so
```

Or on macOS with:

```sh
nm -gU nimcache/libproducer.dylib
```

The list contains the 20 public procedures from `producer.nim` and
`support.nim`, three custom ownership hooks required by public types, and
one library-specific `NimMain` alias. Private procedures, the original
`NimMain` name, generated default hooks, runtime helpers, and all other archive
symbols remain hidden.

## How the build works

The regular C pipeline eliminates unused public procedures before producing an
object file. The incremental backend gives us a useful interception point:

1. `nim ic --genBif:on` writes semantic `.s.bif` files and pre-merge `.c.nif`
   artifacts.
2. `tools/native_dynlib` reads each application BIF, applies
   `native_dynlib.json`, and selects the remaining exported routines plus custom
   ownership hooks required by public types.
3. It matches the semantic symbol in BIF to the same symbol recorded on a
   `.c.nif` definition, obtaining the exact backend C name.
4. It marks those definitions as liveness roots and lets Nim rerun its normal
   dependency closure and C emission.
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
   from BIF, then uses `.c.nif` for the exact import names.
9. The consumer compiles against the generated Nim module and loads the dynamic
   library directly.

This keeps both policy decisions outside the compiler: BIF decides which Nim
declarations are public, and the platform export list decides which native
symbols the dylib exposes.

## Current boundaries

- Archive promotion supports 64-bit Mach-O on macOS and little-endian ELF64 on
  Linux and FreeBSD.
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
generates bindings from BIF and C NIF, and runs a separate Nim consumer.
