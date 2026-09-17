var releases: int

type
  Resource = ref ResourceObj
  ResourceObj = object
    label: string

  PlatformGraphicsState* = object
    native*: pointer
    projection*: array[4, float32]

  State* = object
    label*: string
    resource: Resource
    graphics*: PlatformGraphicsState

  Lease* = object
    resource: Resource

  Renderer*[Backend] = ref object
    state*: Backend
    enabled*: bool

  FloatTarget* = object
    x*, y*, width*, height*: float32

proc `=destroy`(resource: ResourceObj) =
  inc releases
  `=destroy`(resource.label)

proc newState*(): State =
  State(label: "native", resource: Resource(label: "owned"))

proc newLease*(): Lease =
  Lease(resource: Resource(label: "lease"))

proc label*(lease: Lease): string =
  lease.resource.label

proc releaseCount*(): int =
  releases

proc label*(state: State): string =
  state.label

proc rename*(state: var State, text: string) =
  state.label = text

proc enabled*[Backend](renderer: Renderer[Backend]): bool =
  renderer.enabled

proc `enabled=`*[Backend](renderer: Renderer[Backend], value: bool) =
  renderer.enabled = value

proc target*(): FloatTarget =
  FloatTarget(x: 1, y: 2, width: 3, height: 4)

proc area*(target: FloatTarget): float32 =
  target.width * target.height
