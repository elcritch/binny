import handles
import other/handles as other_handles
import renderer

type
  BackendHandle* = handles.LayerHandle
  BackendState* = object
    handle*: BackendHandle
    other*: other_handles.LayerHandle
    label*: string
  OtherState* = object
    value*: int

var destroyed: int
proc destroyedCount*(): int = destroyed
proc `=destroy`(state: BackendState) =
  if state.label.len > 0:
    inc destroyed
  `=destroy`(state.label)

proc reflectedBackendKind*(renderer: Renderer[BackendState]): int = renderer.backendKind()
