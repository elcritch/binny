# Configuration for sframe_stack_example.nim

switch("cc", "gcc")
switch("path", "..")
switch("stackTrace", "off")
switch("lineTrace", "off")
switch("debugger", "native")

switch("passC", "-O0 -Wa,--gsframe -fomit-frame-pointer -fasynchronous-unwind-tables")
switch("passC", "-I/usr/local/include")
switch("passL", "-L/usr/local/lib -lsframe")
# Disable Nim's frame tracking which adds frame pointers
