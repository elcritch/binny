# Configuration for test_libsframe_comparison.nim

switch("cc", "gcc")
switch("path", ".")
switch("passc", "-O2 -Wa,--gsframe -fomit-frame-pointer -fasynchronous-unwind-tables")
switch("passc", "-I/usr/local/include")
switch("passl", "-L/usr/local/lib -lsframe")