import std/[strformat]

when defined(arm64) or defined(aarch64):
  {.emit: """
#if defined(__aarch64__)
  #include <stdint.h>
  #include <stdlib.h>
  #include <unwind.h>

  #if defined(__APPLE__)
    #define ASM_SYM(name) "_" #name
  #else
    #define ASM_SYM(name) #name
  #endif

typedef struct {
  struct _Unwind_Exception unwind;
  void *nim_ref;
} DemoException;

extern void demo_try_body(void);
extern void my_landing_pad(void);
extern void my_landing_pad_c(void *exc, long long selector);
extern void demo_try_frame(void);

static const uint64_t DEMO_EXCEPTION_CLASS = 0x42494E4E59524546ULL; /* BINNYREF */

static void demo_exception_cleanup(_Unwind_Reason_Code code, struct _Unwind_Exception *exc) {
  (void)code;
  free((void *)exc);
}

void *get_nim_ref_from_unwind(void *exc) {
  DemoException *dexc = (DemoException *)exc;
  return dexc->nim_ref;
}

void throw_nim_ref_with_unwind(void *nim_ref) {
  DemoException *dexc = (DemoException *)calloc(1, sizeof(DemoException));
  if (dexc == NULL) {
    return;
  }

  dexc->unwind.exception_class = DEMO_EXCEPTION_CLASS;
  dexc->unwind.exception_cleanup = demo_exception_cleanup;
  dexc->nim_ref = nim_ref;

  _Unwind_Reason_Code rc = _Unwind_RaiseException(&dexc->unwind);
  if (rc != _URC_NO_REASON) {
    demo_exception_cleanup(rc, &dexc->unwind);
  }
}

_Unwind_Reason_Code demo_personality(
    int version,
    _Unwind_Action actions,
    uint64_t exception_class,
    struct _Unwind_Exception *exc,
    struct _Unwind_Context *ctx) {
  if (version != 1) {
    return _URC_FATAL_PHASE1_ERROR;
  }

  if (exception_class != DEMO_EXCEPTION_CLASS) {
    return _URC_CONTINUE_UNWIND;
  }

  if (actions & _UA_SEARCH_PHASE) {
    return _URC_HANDLER_FOUND;
  }

  if (actions & _UA_CLEANUP_PHASE) {
    _Unwind_SetGR(ctx, __builtin_eh_return_data_regno(0), (uintptr_t)exc);
    _Unwind_SetGR(ctx, __builtin_eh_return_data_regno(1), 1);
    _Unwind_SetIP(ctx, (uintptr_t)&my_landing_pad);
    return _URC_INSTALL_CONTEXT;
  }

  return _URC_CONTINUE_UNWIND;
}

__asm__(
".text\n"
".p2align 2\n"
".globl " ASM_SYM(my_landing_pad) "\n"
ASM_SYM(my_landing_pad) ":\n"
"  .cfi_startproc\n"
"  bl " ASM_SYM(my_landing_pad_c) "\n"
"  ldp x29, x30, [sp], #16\n"
"  ret\n"
"  .cfi_endproc\n"
);

__asm__(
".text\n"
".p2align 2\n"
".globl " ASM_SYM(demo_try_frame) "\n"
ASM_SYM(demo_try_frame) ":\n"
"  .cfi_startproc\n"
"  .cfi_personality 155, " ASM_SYM(demo_personality) "\n"
"  stp x29, x30, [sp, #-16]!\n"
"  mov x29, sp\n"
"  .cfi_def_cfa w29, 16\n"
"  .cfi_offset w30, -8\n"
"  .cfi_offset w29, -16\n"
"  bl " ASM_SYM(demo_try_body) "\n"
"  ldp x29, x30, [sp], #16\n"
"  ret\n"
"  .cfi_endproc\n"
);

  #undef ASM_SYM
#endif
  """.}

  proc runDemoTryFrame()
    {.cdecl, importc: "demo_try_frame".}

  proc throwNimRefWithUnwind(payload: pointer)
    {.cdecl, importc: "throw_nim_ref_with_unwind".}

  proc getNimRefFromUnwind(exc: pointer): pointer
    {.cdecl, importc: "get_nim_ref_from_unwind".}

  var last_caught*: ref CatchableError
  var keep_alive: ref CatchableError

  proc demoTryBody()
      {.cdecl, exportc: "demo_try_body", noinline.} =
    echo "try: before _Unwind_RaiseException"
    let payload = newException(ValueError, "nim stdlib exception payload")
    keep_alive = payload
    throwNimRefWithUnwind(cast[pointer](payload))
    echo "try: no handler found (unexpected in this demo)"

  proc myLandingPadC(exc: pointer, selector: int64)
      {.cdecl, exportc: "my_landing_pad_c", noinline.} =
    if selector == 0:
      echo "cleanup-only landing pad"
      return

    let nim_ref = cast[ref CatchableError](getNimRefFromUnwind(exc))
    last_caught = nim_ref
    echo &"landing pad: selector={selector} msg={nim_ref.msg}"

  proc runSimpleTryCatch() =
    last_caught = nil
    runDemoTryFrame()
    if last_caught.isNil:
      echo "catch: no exception captured"
    else:
      echo &"catch: msg={last_caught.msg}"

when isMainModule:
  when defined(arm64) or defined(aarch64):
    echo "libunwind try/catch with Nim stdlib exception payload:"
    runSimpleTryCatch()
  else:
    echo "This example is only implemented for AArch64."
