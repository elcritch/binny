type
  Permission* = enum
    read
    write

  Options* = object
    permissions*: set[Permission]

proc configure*(options: Options): Options {.exportabi.} =
  options
