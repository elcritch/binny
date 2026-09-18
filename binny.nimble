version = "0.5.17"
author = "Jaremy Creechley"
description = "Build native Nim dynamic libraries and strongly typed bindings without C export shims"
license = "MIT"

feature "reference":
  requires "libbacktrace"
  # requires "https://sourceware.org/git/binutils-gdb.git"
  # requires "https://github.com/gimli-rs/gimli.git"

feature "test":
  requires "bumpy >= 1.1.3"
