# Per-file NimScript for examples/stackwalk_amd64.nim

switch("cc", "gcc")
switch("passC", "-fasynchronous-unwind-tables -Wa,--gsframe")

