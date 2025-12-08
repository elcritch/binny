# Per-file NimScript for examples/stackwalk_amd64_nim.nim
# Use Nim's stacktrace override instead of default stack traces
switch("cc", "gcc")
switch("stackTrace", "off")
switch("define", "release")
switch("debugger", "native")
switch("define", "nimStackTraceOverride")
switch("passC", "-O1 -Wa,--gsframe -fomit-frame-pointer -fasynchronous-unwind-tables")
