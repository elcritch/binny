## Checked, owned BIF loading and cursor/query utilities for long-lived tools.
##
## `load` validates and copies the token storage, leaving no file or mapping
## resident after it returns. `tryLoad` is the non-raising workspace-scan
## boundary.

import ./native_dynlib/nif/bif_safe as bif_safe_impl
import ./native_dynlib/nif/[nifcore, nifqueries]

export bif_safe_impl except beginStore, endStore, getOrQuit,
  path, readRawData
export nifcore except adoptForeignTokens
export nifqueries
