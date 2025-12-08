# Configuration for sframe_stack_example.nim

switch("cc", "gcc")
switch("path", "..")
switch("opt", "speed")
switch("passc", "-O2 -Wa,--gsframe -fomit-frame-pointer -fasynchronous-unwind-tables")
switch("passc", "-I/usr/local/include")
switch("passl", "-L/usr/local/lib -lsframe")
# Disable Nim's frame tracking which adds frame pointers
switch("d", "release")
switch("stackTrace", "off")
switch("lineTrace", "off")
