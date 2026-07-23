## Safe BIF loading and cursor/query utilities for long-lived tooling.
##
## `load` copies token storage into owned memory, validates the complete file,
## and closes the input before returning. `tryLoad` is the non-raising boundary
## intended for workspace scans where one stale cache entry must not stop the
## process.

import ./native_dynlib/nif/bif as bif_impl
import ./native_dynlib/nif/[nifcore, nifqueries]

export bif_impl except beginStore, endStore, getOrQuit,
  loadMappedProcessLifetime, path, readRawData
export nifcore except adoptForeignTokens
export nifqueries
