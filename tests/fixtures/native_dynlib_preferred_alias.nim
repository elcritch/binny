import ./[native_dynlib_preferred_alias_dependency, native_dynlib_preferred_alias_shared]

type
  Permission* = enum
    read
    write

  PermissionSet* = set[Permission]

  EntrySeq* = seq[Entry]
  StringSeq* = seq[string]
  IntSlice* = Slice[int]
  IntSlices* = seq[IntSlice]

  Options* = object
    permissions*: set[Permission]
    entries*: seq[Entry]
    labels*: seq[string]

var ensuredEntry: Entry

proc ensureEntry*(): var Entry {.exportabi.} =
  ensuredEntry

proc passSlice*(value: Slice[int]): Slice[int] {.exportabi.} =
  value

proc slices*(): seq[Slice[int]] {.exportabi.} =
  @[]

proc configure*(options: Options): Options {.exportabi.} =
  options

proc configureDependent*(options: DependentOptions): DependentOptions {.exportabi.} =
  options
