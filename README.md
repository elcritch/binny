Binny (Nim) — minimal sframe, elf, and dwarf library for Nim

WIP - see `tests/` and `examples/`.

The SFrame walker appears to be working on AMD64! The ELF parser appears to work well.

The DWARF library stuff needs more work.

The experimental `binny/native_dynlib` module generates native Nim bindings
from semantic BIF and `.abi.nif` artifacts emitted by the corresponding Nim
compiler branch. It reconstructs objects, inheritance, and case branches, then
emits compile-time size, alignment, and field-offset checks. See
`examples/nim_native_dynlib` for a complete producer and consumer.

## Native dynamic-library bindings

Add Binny as an Atlas dependency:

```nim
requires "https://github.com/elcritch/binny"
```

Then resolve dependencies with `atlas install` and generate a binding module:

```nim
import binny/native_dynlib

let config = initNativeBindingsConfig(
  sourcePath = "src/plugin.nim",
  manifestPath = "build/libplugin.abi.nif",
  nimcacheDir = "build/nimcache")

discard config.writeNativeBindings("generated/plugin_abi.nim")
```

By default, the generated `dynlib` imports use the library name recorded in the
ABI manifest, such as `libplugin.so`. The operating-system loader can resolve it
through the normal install name, rpath, or loader search path, so generated
bindings are relocatable. Set `libraryOverride` in the configuration only when
a build needs a specific loader name or path.
