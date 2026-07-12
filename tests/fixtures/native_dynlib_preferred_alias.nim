import ./[native_dynlib_preferred_alias_dependency, native_dynlib_preferred_alias_shared]

type
  Permission* = enum
    read
    write

  PermissionSet* = set[Permission]

  EntrySeq* = seq[Entry]
  StringSeq* = seq[string]

  Options* = object
    permissions*: set[Permission]
    entries*: seq[Entry]
    labels*: seq[string]

proc configure*(options: Options): Options {.exportabi.} =
  options

proc configureDependent*(options: DependentOptions): DependentOptions {.exportabi.} =
  options
