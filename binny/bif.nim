## Memory-mapped BIF loading and cursor/query utilities.
##
## `load` borrows its token block from a mapping that remains resident for the
## process lifetime. Long-lived tools should import `binny/bif_safe` instead.

import ./native_dynlib/nif/bif as bif_impl
import ./native_dynlib/nif/[nifcore, nifqueries]

export bif_impl except beginStore, endStore, getOrQuit,
  path, readRawData
export nifcore except adoptForeignTokens
export nifqueries
