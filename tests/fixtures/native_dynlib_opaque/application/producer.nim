import ../backend

type
  NativeRenderer* = Renderer[State]
  NativeState* = State
  NativeLease* = Lease
  NativeTarget* = FloatTarget

proc newRenderer*(): NativeRenderer =
  result = NativeRenderer(state: newState())
  backend.`enabled=`(result, true)
  doAssert backend.enabled(result)

proc newNativeState*(): NativeState =
  newState()

proc newNativeLease*(): NativeLease =
  newLease()

proc leaseLabel*(lease: NativeLease): string =
  lease.label()

proc stateLabel*(state: NativeState): string =
  state.label()

proc renameState*(state: var NativeState, text: string) =
  state.rename(text)

proc consumeState*(state: sink NativeState): string =
  state.label()

proc releasedCount*(): int =
  releaseCount()

proc presentationTarget*(): NativeTarget =
  target()

proc targetArea*(target: NativeTarget): float32 =
  area(target)
