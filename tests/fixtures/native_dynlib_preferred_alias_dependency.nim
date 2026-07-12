import ./native_dynlib_preferred_alias_shared

type
  EntryList* = seq[Entry]

  DependentOptions* = object
    entries*: seq[Entry]
