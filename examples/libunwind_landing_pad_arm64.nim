import std/[strformat]

type
  DemoException = object
    thrownObject: pointer

when defined(arm64) or defined(aarch64):
  {.emit: """
#if defined(__aarch64__)
  #if defined(__APPLE__)
    #define ASM_SYM(name) "_" #name
  #else
    #define ASM_SYM(name) #name
  #endif

extern void my_landing_pad_c(void *exc, long long selector);

__asm__(
".text\n"
".p2align 2\n"
".globl " ASM_SYM(my_landing_pad) "\n"
ASM_SYM(my_landing_pad) ":\n"
"  .cfi_startproc\n"
"  .cfi_undefined x30\n"
"  b " ASM_SYM(my_landing_pad_c) "\n"
"  .cfi_endproc\n"
);

__asm__(
".text\n"
".p2align 2\n"
".globl " ASM_SYM(invoke_landing_pad_demo) "\n"
ASM_SYM(invoke_landing_pad_demo) ":\n"
"  .cfi_startproc\n"
"  b " ASM_SYM(my_landing_pad) "\n"
"  .cfi_endproc\n"
);

  #undef ASM_SYM
#endif
  """.}

  proc invokeLandingPadDemo(exc: pointer, selector: int64)
    {.cdecl, importc: "invoke_landing_pad_demo".}

  var pending_exception: ptr DemoException
  var pending_selector: int64
  var cleanup_seen: bool
  var demo_exception = DemoException(thrownObject: cast[pointer](0xB16B00B5'u))

  proc clearPending() =
    pending_exception = nil
    pending_selector = 0
    cleanup_seen = false

  proc myLandingPadC(exc: pointer, selector: int64)
      {.cdecl, exportc: "my_landing_pad_c".} =
    if selector == 0:
      cleanup_seen = true
    else:
      pending_exception = cast[ptr DemoException](exc)
      pending_selector = selector

  proc throwDemo(exc: ptr DemoException, selector: int64): bool =
    clearPending()
    invokeLandingPadDemo(exc, selector)
    result = pending_exception != nil

  proc runSimpleTryCatch() =
    echo "try: before throw"
    if throwDemo(addr demo_exception, 7):
      let demo = pending_exception[]
      echo &"catch: selector={pending_selector} thrownObject=0x{cast[uint](demo.thrownObject):x}"
      clearPending()
      return
    echo "try: after throw (no exception)"

  proc runCleanupDemo() =
    clearPending()
    invokeLandingPadDemo(addr demo_exception, 0)
    if cleanup_seen:
      echo "cleanup selector=0 -> would call _Unwind_Resume(exc)"

when isMainModule:
  when defined(arm64) or defined(aarch64):
    echo "simple try/catch via landing-pad trampoline:"
    runSimpleTryCatch()
    echo "cleanup-only dispatch:"
    runCleanupDemo()
  else:
    echo "This example is only implemented for AArch64."
