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
    ntAlias
    ntDistinct
    ntArray
    ntSequence
    ntSet
    ntTuple
    ntOpenArray
    ntRange
    ntProc
    ntImportedGeneric

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
    indexTypeSymbol*: string
    elementTypeSymbol*: string
    arrayLength*: int64
    size*: int64
    alignment*: int64
    layoutFingerprint*: string
    inheritable*: bool
    packed*: bool
    union*: bool
    importModule*: string
    ## True when ``importModule`` supplies the type declaration itself.
    imported*: bool
    ## Signature for anonymous proc types. These are rendered inline instead
    ## of emitted as standalone declarations.
    procInfo*: NativeProc
    genericArguments*: seq[string]
    equivalentTypeSymbols*: seq[string]
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
    returnByVar*: bool
    returnLowering*: NativeLoweringMode
    callConv*: string
    closureEnv*: bool
    varargs*: bool
    discardable*: bool
    params*: seq[NativeParam]

  NativeHookStatus* = enum
    nhCustom
    nhForbidden

  NativeHook* = object
    typeSymbol*: string
    kind*: string
    status*: NativeHookStatus
    procInfo*: NativeProc

  NativeApi* = object
    libraryName*: string
    initSymbol*: string
    types*: seq[NativeType]
    hooks*: seq[NativeHook]
    procs*: seq[NativeProc]
