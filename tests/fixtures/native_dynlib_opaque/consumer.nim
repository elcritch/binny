import opaque_abi

static:
  doAssert not declared(PlatformGraphicsState)
  doAssert not compiles(default(NativeRenderer).state)
  doAssert not compiles(default(NativeState).graphics)
  doAssert not compiles(default(NativeTarget).width)

proc exercise() =
  doAssert releasedCount() == 0
  block:
    var original = newRenderer()
    let alias = original
    original = nil
    doAssert alias.enabled()
    alias.enabled = false
    doAssert not alias.enabled()
    doAssert releasedCount() == 0
  doAssert releasedCount() == 1
  block:
    var original = newNativeState()
    var copied = original
    renameState(copied, "copy")
    doAssert stateLabel(original) == "native"
    doAssert stateLabel(copied) == "copy"
    copied = copied
    copied = newNativeState()
    doAssert releasedCount() == 1
    var moved = move(original)
    doAssert stateLabel(original) == ""
    doAssert consumeState(moved) == "native"
    doAssert stateLabel(moved) == "native" # sink copies when used again
    doAssert releasedCount() == 1
  doAssert releasedCount() == 3
  doAssert consumeState(newNativeState()) == "native"
  doAssert releasedCount() == 4
  # Even one ref-sized managed field requires Nim's indirect result ABI.
  block:
    let original = newNativeLease()
    var copied = original
    copied = default(NativeLease)
    doAssert leaseLabel(original) == "lease"
    doAssert releasedCount() == 4
  doAssert releasedCount() == 5
  # A homogeneous float aggregate must retain its register-based ABI shape.
  let target = presentationTarget()
  doAssert targetArea(target) == 12

exercise()
