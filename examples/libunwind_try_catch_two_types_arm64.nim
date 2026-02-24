type
  ThrowKind = enum
    tkValue = 0
    tkIo = 1

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
  long long selector;
} DemoException;

extern void demo_try_body(int kind);
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

void throw_nim_exc_with_unwind(void *nim_exc, long long selector) {
  DemoException *dexc = (DemoException *)calloc(1, sizeof(DemoException));
  if (dexc == NULL) {
    return;
  }

  dexc->unwind.exception_class = DEMO_EXCEPTION_CLASS;
  dexc->unwind.exception_cleanup = demo_exception_cleanup;
  dexc->nim_exc = nim_exc;
  dexc->selector = selector;

  _Unwind_Reason_Code rc = _Unwind_RaiseException(&dexc->unwind);
  if (rc != _URC_NO_REASON) {
    demo_exception_cleanup(rc, &dexc->unwind);
  }
}

void delete_unwind_exc(void *exc) {
  _Unwind_DeleteException((struct _Unwind_Exception *)exc);
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
    DemoException *dexc = (DemoException *)exc;
    _Unwind_SetGR(ctx, __builtin_eh_return_data_regno(0), (uintptr_t)exc);
    _Unwind_SetGR(ctx, __builtin_eh_return_data_regno(1), (uintptr_t)dexc->selector);
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

  proc runDemoTryFrame(kind: cint)
    {.cdecl, importc: "demo_try_frame".}

  proc throwNimExcWithUnwind(payload: pointer, selector: int64)
    {.cdecl, importc: "throw_nim_exc_with_unwind".}

  proc getNimExcFromUnwind(exc: pointer): pointer
    {.cdecl, importc: "get_nim_exc_from_unwind".}

  proc deleteUnwindExc(exc: pointer)
    {.cdecl, importc: "delete_unwind_exc".}

  proc cExit(code: cint)
    {.importc: "_Exit", header: "<stdlib.h>", noreturn.}

  var keep_alive*: seq[ref CatchableError]
  var pending_exc*: ref CatchableError
  var pending_selector*: int64
  var catch_count_value*: int
  var catch_count_io*: int

  proc catchValueBlock(exc: ref ValueError) =
    inc catch_count_value
    echo "catch(ValueError): " & exc.msg

  proc catchIoBlock(exc: ref IOError) =
    inc catch_count_io
    echo "catch(IOError): " & exc.msg

  proc demoTryBody(kind: cint)
      {.cdecl, exportc: "demo_try_body", noinline.} =
    var payload: ref CatchableError
    var selector: int64
    case kind
    of 0:
      echo "try(value): before throw"
      payload = newException(ValueError, "bad value")
      selector = 1
    of 1:
      echo "try(io): before throw"
      payload = newException(IOError, "disk read failed")
      selector = 2
    else:
      echo "try(unknown): before throw"
      payload = newException(CatchableError, "unknown throw kind")
      selector = 0

    keep_alive.add(payload)
    throwNimExcWithUnwind(cast[pointer](payload), selector)
    echo "try: no handler found (unexpected)"

  proc myLandingPadC(exc: pointer, selector: int64)
      {.cdecl, exportc: "my_landing_pad_c", noinline.} =
    if selector == 0:
      return
    let nim_exc = cast[ref CatchableError](getNimExcFromUnwind(exc))
    pending_exc = nim_exc
    pending_selector = selector
    deleteUnwindExc(exc)

  proc runOuter(kind: ThrowKind) =
    pending_exc = nil
    pending_selector = 0
    case kind
    of tkValue:
      let before = catch_count_value
      runDemoTryFrame(cint(tkValue))
      if pending_selector == 1 and (pending_exc of ValueError):
        catchValueBlock(cast[ref ValueError](pending_exc))
      elif not pending_exc.isNil:
        echo "catch(value-mismatch): " & pending_exc.msg
      if catch_count_value == before + 1:
        echo "post(value): done"
      else:
        echo "post(value): no exception captured"
    of tkIo:
      let before = catch_count_io
      runDemoTryFrame(cint(tkIo))
      if pending_selector == 2 and (pending_exc of IOError):
        catchIoBlock(cast[ref IOError](pending_exc))
      elif not pending_exc.isNil:
        echo "catch(io-mismatch): " & pending_exc.msg
      if catch_count_io == before + 1:
        echo "post(io): done"
      else:
        echo "post(io): no exception captured"

when isMainModule:
  when defined(arm64) or defined(aarch64):
    echo "libunwind try/catch from one outer proc:"
    runOuter(tkValue)
    runOuter(tkIo)
    cExit(0)
  else:
    echo "This example is only implemented for AArch64."
