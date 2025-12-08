# Configuration for test_sframe_simple.nim

switch("cc", "gcc")
switch("path", ".")
switch("passc", "-O2 -Wa,--gsframe -fomit-frame-pointer -fasynchronous-unwind-tables")