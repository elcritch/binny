import binny/bif as bif_mmap
import binny/bif_safe as bif_owned

static:
  doAssert compiles(bif_mmap.load("module.bif"))
  doAssert compiles(bif_owned.load("module.bif"))
  doAssert compiles(BifLoadLimits())
