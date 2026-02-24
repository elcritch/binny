import std/[os, osproc]

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
  void *nim_exc;
} DemoException;

extern void demo_try_value_body(void);
extern void demo_try_io_body(void);
extern void my_landing_pad(void);
extern void my_landing_pad_c(void *exc, long long selector);

static const uint64_t DEMO_EXCEPTION_CLASS = 0x42494E4E59543245ULL; /* BINNYT2E */

static void demo_exception_cleanup(_Unwind_Reason_Code code, struct _Unwind_Exception *exc) {
  (void)code;
  free((void *)exc);
}

void *get_nim_exc_from_unwind(void *exc) {
  DemoException *dexc = (DemoException *)exc;
  return dexc->nim_exc;
}

void throw_nim_exc_with_unwind(void *nim_exc) {
  DemoException *dexc = (DemoException *)calloc(1, sizeof(DemoException));
  if (dexc == NULL) {
    return;
  }

  dexc->unwind.exception_class = DEMO_EXCEPTION_CLASS;
  dexc->unwind.exception_cleanup = demo_exception_cleanup;
  dexc->nim_exc = nim_exc;

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
".globl " ASM_SYM(demo_try_frame_throw_value) "\n"
ASM_SYM(demo_try_frame_throw_value) ":\n"
"  .cfi_startproc\n"
"  .cfi_personality 155, " ASM_SYM(demo_personality) "\n"
"  stp x29, x30, [sp, #-16]!\n"
"  mov x29, sp\n"
"  .cfi_def_cfa w29, 16\n"
"  .cfi_offset w30, -8\n"
"  .cfi_offset w29, -16\n"
"  bl " ASM_SYM(demo_try_value_body) "\n"
"  ldp x29, x30, [sp], #16\n"
"  ret\n"
"  .cfi_endproc\n"
);

__asm__(
".text\n"
".p2align 2\n"
".globl " ASM_SYM(demo_try_frame_throw_io) "\n"
ASM_SYM(demo_try_frame_throw_io) ":\n"
"  .cfi_startproc\n"
"  .cfi_personality 155, " ASM_SYM(demo_personality) "\n"
"  stp x29, x30, [sp, #-16]!\n"
"  mov x29, sp\n"
"  .cfi_def_cfa w29, 16\n"
"  .cfi_offset w30, -8\n"
"  .cfi_offset w29, -16\n"
"  bl " ASM_SYM(demo_try_io_body) "\n"
"  ldp x29, x30, [sp], #16\n"
"  ret\n"
"  .cfi_endproc\n"
);

  #undef ASM_SYM
#endif
  """.}

  proc runDemoTryFrameThrowValue()
    {.cdecl, importc: "demo_try_frame_throw_value".}

  proc runDemoTryFrameThrowIo()
    {.cdecl, importc: "demo_try_frame_throw_io".}

  proc throwNimExcWithUnwind(payload: pointer)
    {.cdecl, importc: "throw_nim_exc_with_unwind".}

  proc getNimExcFromUnwind(exc: pointer): pointer
    {.cdecl, importc: "get_nim_exc_from_unwind".}

  proc cExit(code: cint)
    {.importc: "_Exit", header: "<stdlib.h>", noreturn.}

  var keep_alive*: seq[ref CatchableError]
  var catch_count_value*: int
  var catch_count_io*: int

  proc catchValueBlock(exc: ref ValueError) =
    inc catch_count_value
    echo "catch(ValueError): " & exc.msg

  proc catchIoBlock(exc: ref IOError) =
    inc catch_count_io
    echo "catch(IOError): " & exc.msg

  proc dispatchCatch(exc: ref CatchableError) =
    if exc of ValueError:
      catchValueBlock(cast[ref ValueError](exc))
    elif exc of IOError:
      catchIoBlock(cast[ref IOError](exc))
    else:
      echo "catch(default): " & exc.msg

  proc demoTryValueBody()
      {.cdecl, exportc: "demo_try_value_body", noinline.} =
    echo "try(value): before throw"
    let payload = newException(ValueError, "bad value")
    keep_alive.add(payload)
    throwNimExcWithUnwind(cast[pointer](payload))
    echo "try(value): no handler found (unexpected)"

  proc demoTryIoBody()
      {.cdecl, exportc: "demo_try_io_body", noinline.} =
    echo "try(io): before throw"
    let payload = newException(IOError, "disk read failed")
    keep_alive.add(payload)
    throwNimExcWithUnwind(cast[pointer](payload))
    echo "try(io): no handler found (unexpected)"

  proc myLandingPadC(exc: pointer, selector: int64)
      {.cdecl, exportc: "my_landing_pad_c", noinline.} =
    if selector == 0:
      return
    let nim_exc = cast[ref CatchableError](getNimExcFromUnwind(exc))
    dispatchCatch(nim_exc)

  proc runValueDemo() =
    runDemoTryFrameThrowValue()
    if catch_count_value == 1:
      echo "post(value): done"
    else:
      echo "post(value): no exception captured"

  proc runIoDemo() =
    runDemoTryFrameThrowIo()
    if catch_count_io == 1:
      echo "post(io): done"
    else:
      echo "post(io): no exception captured"

when isMainModule:
  when defined(arm64) or defined(aarch64):
    if paramCount() == 1 and paramStr(1) == "value":
      runValueDemo()
      cExit(0)
    elif paramCount() == 1 and paramStr(1) == "io":
      runIoDemo()
      cExit(0)
    else:
      let self = quoteShell(getAppFilename())
      echo "libunwind try/catch with two Nim stdlib exception types:"
      discard execCmd(self & " value")
      discard execCmd(self & " io")
  else:
    echo "This example is only implemented for AArch64."
