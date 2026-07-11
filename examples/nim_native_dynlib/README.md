# Native Nim dynamic-library example

This experiment keeps native binding generation outside the compiler. The
compiler owns only facts that require backend authority:

- `{.exportabi.}` and its final Itanium-style symbol;
- collection of concrete exported instances;
- a compact `<library>.abi.nif` mapping semantic NIF symbols to backend symbols,
  with compiler, target, memory-manager, and allocator facts.

`exportabi` reuses Nim's ordinary external-export and shared-library visibility
machinery. It differs from `exportc` only in who chooses the external name:
the backend fills it with a signature-aware Nim name instead of accepting a
fixed C name from the source pragma. The pragma requires the experimental
`abi` feature while this native ABI contract is still evolving; `--emitBif`
itself remains available independently of that language feature.

To support ABI exports whose signatures use public types from imported modules,
the experimental feature also gives externally linkable names to compatible
custom hooks attached to public types. The manifest exposes only the hooks that
are reachable from the library's exported ABI surface.

Binny's `binny/native_dynlib` module reads that manifest together with the root
module's stable semantic BIF and emits `producer_abi.nim`. That generated module
contains real Nim `object` and `ref object` declarations, native `nimcall`
dynlib imports, and public wrappers that initialize the library before use.

The first slice supports non-generic procedures and auto-managed object graphs.
The example crosses `string`, a by-value object, and nested `ref object` values,
then performs ordinary public field reads and writes in the consumer. Producer
and consumer are deliberately compiled with the same compiler, ORC, and
allocator mode.

Custom attached ownership hooks reachable from exported signatures are emitted
as native ABI exports and recreated as forwarding hooks in the generated
binding. Compiler-generated structural hooks remain local and are lifted again
by the consumer compiler. The fixture verifies custom `=copy` and `=destroy`
calls against producer-side counters.

The consumer prints the native library initialization and calls the exported
`message` proc. Edit the string returned by `message` in `producer.nim`, run
`nim producer` followed by `nim consumer`, and check that the consumer prints
the updated value. This gives a visible sanity check that the generated binding
called into the rebuilt dynamic library.

Case objects and object inheritance are reconstructed from semantic BIF
definitions and the concrete layouts in `.abi.nif`. The example also resolves
an exported type and procedures from `support.nim` through the manifest's module
table. Open generics, exceptions, and runtime ABI mismatch rejection are not
supported yet.

The generator includes the NIF/BIF reader code it needs, so it has no Nimony
checkout or `NIMONY_DIR` requirement. Build a matching ABI-branch compiler that
emits format-4 native ABI manifests, then run its `e2e` task from this directory:

```sh
/path/to/abi-nim e2e
```

When that compiler is on `PATH`, this is simply:

```sh
nim e2e
```

The tasks use the compiler that launched them for the producer, generator, and
consumer, so all stages share one ABI.

For incremental work, `nim producer` rebuilds the dynamic library and ABI
artifacts. `nim bindings` regenerates the module, and `nim consumer` regenerates
the bindings, builds, and runs the consumer. `nim build` builds every stage,
while `nim e2e` (or `nim nativeDynlibTest`) also runs the consumer and verifies
that the move-only binding cannot be copied.

The compiler stages the manifest in `nimcache`, then publishes one manifest
beside the successfully linked dynamic library. This example keeps those build
artifacts in `nimcache`; the generated binding module is in `generated/`. The
public manifest covers the complete library export surface; its module table
identifies every source module that contributed an exported procedure.

The shared library and its stable semantic BIF are produced together by an
ordinary `nim c --experimental:abi --emitBif:on --app:lib` build. This reuses
the IC artifact format without requiring the target library to build through
`nim ic`. C-header generation is not part of this first native proof.
