Binny (Nim) — minimal sframe, elf, and dwarf library for Nim

WIP - see `tests/` and `examples/`.

The SFrame walker appears to be working on AMD64! The ELF parser appears to work well.

The DWARF library stuff needs more work.

The experimental `binny/native_dynlib` module generates native Nim bindings
from semantic BIF and `.abi.nif` artifacts emitted by the corresponding Nim
compiler branch. See `examples/nim_native_dynlib` for a complete producer and
consumer.
