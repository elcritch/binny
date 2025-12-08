# Configuration for sframe_stack_example.nim

switch("cc", "gcc")
switch("path", "..")
switch("stackTrace", "off")
switch("lineTrace", "off")
switch("debugger", "native")
switch("define", "release")
#switch("opt", "none")
switch("passC", "-Wa,--gsframe -fomit-frame-pointer -fasynchronous-unwind-tables")
switch("passC", "-I/usr/local/include")
switch("passL", "-Wa,--gsframe -lctf -lsframe -L/usr/local/lib")
# Disable Nim's frame tracking which adds frame pointers
