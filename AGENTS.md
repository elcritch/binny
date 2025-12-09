# Repository Guidelines

## Project Structure & Module Organization
- `binny/` hosts production Nim; `sframe/*` implements encoders/decoders/walkers, `elfparser.nim` ingests ELF metadata, and `binny.nim` re-exports the API.
- `docs/` and `examples/` bundle specs (start with `docs/sframe-spec.md`) plus runnable demos (`stackwalk_amd64.nim`, `gen_sframe_example.sh`, `Makefile.sframe`).
- `tests/` stores runnable `t*.nim` specs that `config.nims` iterates; keep fixtures adjacent to their tests.
- `tools/` ships utilities like `tools/sframe_dump.nim`; `deps/` vendors libsframe/binutils and other Atlas-managed code.

## Build, Test, and Development Commands
- `nim c binny.nim` builds the aggregate module and surfaces missing imports or path updates early.
- `nim test` runs all the tests
- `nim c -r tests/tfile.nim`
- `nim c -r tools/sframe_dump.nim examples/out.sframe --base=0x...` inspects extracted sections

## Coding Style & Naming Conventions
- Use two-space indentation, `snake_case` locals, camelCase procs, UpperCamelCase types, and export with `*`.
- List imports explicitly (`import std/[os,strformat]`), keep modules narrowly scoped, and avoid global state.
- Format with `nimpretty`/`nim fmt`; only add comments where binary semantics or errata would surprise reviewers.

## Testing Guidelines
- Name specs `tests/t*.nim` so the `test` task in `config.nims` can iterate them via `nim c -r`.
- Exercise both AMD64 and AArch64 whenever walker logic changes, reusing `sframe/mem_sim` for deterministic stacks.
- Mirror `tests/test_libsframe_comparison.nim` for libsframe parity checks and gate long runs behind a flag.

## Commit & Pull Request Guidelines
- Use short imperative subjects like `rename to binny` or `Refactor walker (#1)` and capture risks/tests in the body.
- PRs should split unrelated work, call out affected architectures/docs, list the exact commands run, and include sample `.sframe` or stack traces for walker changes.

## Security & Configuration Tips
- All dependencies live in `deps/`; never fetch runtime packages with Nimble — update vendors through Atlas instead.
- Keep `nim.cfg`'s Atlas block (`--noNimblePath`, `--path:"deps/..."`) accurate whenever you add modules.
- Artifacts belong in `.nimcache` or throwaway paths referenced by `config.nims`; do not commit generated binaries or `.sframe` outputs.
