# Configuration for test_sframe_comparison.nim

switch("cc", "gcc")
switch("path", ".")
switch("passC", "-O2 -Wa,--gsframe -fomit-frame-pointer -fasynchronous-unwind-tables")
switch("passc", "-I/usr/local/include")
switch("passl", "-L/usr/local/lib -lsframe")
