## Generates native Nim dynamic-library bindings from compiler ABI artifacts.
##
## The required NIF/BIF reader support is vendored in ``native_dynlib/nif``.

import native_dynlib/[artifacts, bifreader]

proc generateNativeBindings*(nimcacheDir, sourcePath, manifestPath,
    libraryPath: string): string =
  ## Returns a Nim module that binds the ABI exports described by ``manifestPath``.
  ##
  ## ``nimcacheDir`` must contain the semantic BIF files produced alongside the
  ## library with ``--emitBif:on``. ``sourcePath`` identifies the library's root
  ## Nim module, and ``libraryPath`` is embedded in the generated dynlib imports.
  let
    bifPath = findSemanticBif(nimcacheDir, sourcePath)
    api = readNativeApi(bifPath, manifestPath)
  result = generateNativeModule(api, libraryPath)
