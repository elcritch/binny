# Binny

Binny provides tools for interacting with binaries including generating Nim native dynamic libraries. Additionally it supports ELF parsing tools and SFrame support.

Build native Nim dynamic libraries and strongly typed Nim bindings from compiler metadata—without C export shims or export pragmas.

Binny turns ordinary public Nim routines (`proc name*`) into a filtered native dynamic-library API. It reads semantic BIF to identify the public surface, matches those declarations to their exact backend symbols, and reconstructs the Nim types and ownership hooks needed by consumers.

The native-library workflow is experimental. The no-pragma archive promotion
supports 64-bit Mach-O on macOS and little-endian ELF64 on Linux and FreeBSD. Windows should be possible, but I don't have a Windows Machine.

It requires a Nim devel compiler with `--genBif`, `nim ic`, and `nifler`.

## Why try it?

- Keep Nim's `*` marker as the source of truth for the public API.
- Export native Nim routines without `exportc` or producer
  wrappers.
- Preserve objects, refs, inheritance, case objects, containers, and custom
  ownership hooks in generated bindings.
- Export only the BIF-selected procedures and required runtime entry points.
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

After the compiler artifacts and dylib exist, generate BIF-derived consumer
bindings with:

```nim
import binny/native_dynlib

let config = initBifNativeBindingsConfig(
  sourcePath = "src/plugin.nim",
  nimcacheDir = "build/nimcache",
  libraryName = "build/libplugin",
)

discard config.writeNativeBindings("generated/plugin_abi.nim")
```

When `libraryName` has no extension, Binny appends `.dylib` on macOS or `.so`
on Linux and FreeBSD.

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
nim c binny.nim
nim test
```

The CI uses Nim devel to build the aggregate module, test native binding
generation, and run the native dynamic-library end-to-end workflow on both
Linux and macOS.
