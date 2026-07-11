type
  NativeLoweringMode* = enum
    nlVoid
    nlDirect
    nlIndirect
    nlPointer

  NativeTypeKind* = enum
    ntObject
    ntRefObject
    ntEnum

  NativeEnumValue* = object
    name*: string
    ordinal*: int64

  NativeField* = object
    name*: string
    typeSymbol*: string
    exported*: bool
    offset*: int64
    size*: int64
    alignment*: int64
    managed*: bool
    discriminant*: bool

  NativeRecordPartKind* = enum
    nrField
    nrCase

  NativeRecordPart* = ref object
    case kind*: NativeRecordPartKind
    of nrField:
      field*: NativeField
    of nrCase:
      discriminant*: NativeField
      branches*: seq[NativeBranch]

  NativeBranch* = object
    index*: int
    isElse*: bool
    selectors*: seq[string]
    record*: seq[NativeRecordPart]

  NativeType* = object
    name*: string
    nifSymbol*: string
    typeId*: string
    kind*: NativeTypeKind
    baseTypeSymbol*: string
    size*: int64
    alignment*: int64
    layoutFingerprint*: string
    inheritable*: bool
    packed*: bool
    union*: bool
    enumValues*: seq[NativeEnumValue]
    record*: seq[NativeRecordPart]

  NativeParam* = object
    name*: string
    typeSymbol*: string
    byVar*: bool
    lowering*: NativeLoweringMode
    hiddenLengthCount*: int

  NativeProc* = object
    name*: string
    nifSymbol*: string
    cSymbol*: string
    returnTypeSymbol*: string
    returnLowering*: NativeLoweringMode
    callConv*: string
    closureEnv*: bool
    varargs*: bool
    params*: seq[NativeParam]

  NativeHookStatus* = enum
    nhCustom
    nhForbidden

  NativeHook* = object
    typeSymbol*: string
    kind*: string
    status*: NativeHookStatus
    procInfo*: NativeProc

  NativeModule* = object
    identity*: string
    name*: string

  NativeApi* = object
    abiId*: string
    libraryName*: string
    compilerVersion*: string
    compilerApiVersion*: int64
    rodVersion*: string
    targetOS*: string
    targetCPU*: string
    targetEndian*: string
    targetBits*: int64
    memoryManager*: string
    allocator*: string
    exceptionSystem*: string
    stringMode*: string
    threads*: bool
    initSymbol*: string
    modules*: seq[NativeModule]
    types*: seq[NativeType]
    hooks*: seq[NativeHook]
    procs*: seq[NativeProc]
