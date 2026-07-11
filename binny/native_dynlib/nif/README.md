# NIF and BIF reader support

This directory vendors the minimal NIF/BIF reader dependency closure required by
`binny/native_dynlib`. It is copied from
[nim-lang/nimony PR #2141](https://github.com/nim-lang/nimony/pull/2141), at
commit `7caaae26` (`bif-query-helpers`).

The files are kept local so native dynamic-library binding generation does not
need a separate Nimony checkout.
