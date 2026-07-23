# NIF and BIF reader support

This directory vendors the minimal NIF/BIF reader dependency closure required by
`binny/native_dynlib`. It is copied from
[nim-lang/nimony PR #2141](https://github.com/nim-lang/nimony/pull/2141), at
commit `7caaae26` (`bif-query-helpers`).

The files are kept local so native dynamic-library binding generation does not
need a separate Nimony checkout.

The vendored `bif` module retains its original zero-copy reader, whose mapping
remains resident for the process lifetime. The sibling `bif_safe` module adds
the checked, owned file reader for long-lived tools. Public callers can choose
the matching facade: `binny/bif` for mmap loading or `binny/bif_safe` for
recoverable file loading.
