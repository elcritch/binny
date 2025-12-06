# Repository Guidelines

## Project Structure & Module Organization
- Core library: `sframe.nim`; supporting modules in `sframe/` (e.g., `sframe/elfparser.nim`).
- Tests: `tests/` (Nim files prefixed with `t`, e.g., `tests/tfile.nim`).
- Tools: `tools/` (e.g., `tools/sframe_dump.nim`).
- Examples: `examples/`; Documentation: `docs/`.
- Vendored deps: `deps/` (managed via Atlas; see `nim.cfg` Atlas section with `--noNimblePath`).

## Build, Test, and Development Commands
- Build/run a single file: `nim c -r path/to/file.nim` (e.g., `nim c -r tools/sframe_dump.nim`).
- Run a single test: `nim c -r tests/tfile.nim`.
- Run all tests: `nim test` (driven by `config.nims`, discovers `tests/t*.nim`).
- Atlas-only deps: vendor under `deps/` and reference via `nim.cfg` (add `--path:"deps/<lib>"`). Avoid Nimble; `--noNimblePath` is enforced.

## Coding Style & Naming Conventions
- Indentation: 2 spaces; no tabs.
- Types/enums: PascalCase (e.g., `SFrameHeader`).
- Procs/vars: camelCase (e.g., `encodeHeader`, `funcStartAddress`).
- Constants: UPPER_SNAKE (e.g., `SFRAME_MAGIC`).
- Modules/files: lowercase with optional underscores (e.g., `sframe/elfparser.nim`).

## Testing Guidelines
- Framework: `std/unittest`.
- Location & naming: `tests/` with filenames starting with `t` to be auto-run by `nim test`.
- Quick examples:
  - `nim c -r tests/tfile.nim`
  - `nim c -r tests/twalk_amd64.nim`
- Keep tests deterministic and fast; prefer minimal fixtures under `tests/`.

## Commit & Pull Request Guidelines
- Commit messages: clear, present tense. Prefer Conventional Commits:
  - `feat: add AMD64 walker`
  - `fix: correct FRE decode for ADDR2`
- PRs must:
  - Describe changes and rationale; link issues.
  - Include/adjust tests; all tests must pass (`nim test`).
  - Note updates to `nim.cfg` or `deps/` (Atlas only; do not introduce Nimble).

## Security & Configuration Tips
- Dependencies are Atlas-managed and vendored in `deps/`; never rely on Nimble.
- `nim.cfg` contains the Atlas section (e.g., `--noNimblePath`, `--path:"deps/..."`). Update it when adding deps.
- Avoid committing build artifacts; `nimcache` is set to `.nimcache` via `config.nims`.
