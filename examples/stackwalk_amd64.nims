# Per-file NimScript for examples/stackwalk_amd64.nim

switch("cc", "gcc")
#switch("define", "debug")
switch("stackTrace", "off")
switch("debugger", "native")
switch("opt", "none")
switch("passC", "-Wa,--gsframe -fomit-frame-pointer -fasynchronous-unwind-tables")

