# Configuration for sframe_stack_example.nim

switch("cc", "gcc")
switch("path", "..")
switch("passc", "-O0 -Wa,--gsframe -fomit-frame-pointer -fasynchronous-unwind-tables")
switch("passc", "-I/usr/local/include")
switch("passl", "-L/usr/local/lib -lsframe")
# Disable Nim's frame tracking which adds frame pointers
switch("stackTrace", "off")
switch("lineTrace", "off")
switch("stackTrace", "off")
switch("debugger", "native")
