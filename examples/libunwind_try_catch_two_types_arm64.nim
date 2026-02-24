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
extern void value_landing_pad(void);
extern void io_landing_pad(void);
extern void default_landing_pad(void);
extern void catch_value_from_unwind(void *exc);
extern void catch_io_from_unwind(void *exc);
extern void catch_default_from_unwind(void *exc);

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
    uintptr_t target_ip = (uintptr_t)&default_landing_pad;
    if (dexc->selector == 1) {
      target_ip = (uintptr_t)&value_landing_pad;
    } else if (dexc->selector == 2) {
      target_ip = (uintptr_t)&io_landing_pad;
    }

    _Unwind_SetGR(ctx, __builtin_eh_return_data_regno(0), (uintptr_t)exc);
    _Unwind_SetGR(ctx, __builtin_eh_return_data_regno(1), (uintptr_t)dexc->selector);
    _Unwind_SetIP(ctx, target_ip);
    return _URC_INSTALL_CONTEXT;
  }

  return _URC_CONTINUE_UNWIND;
}

__asm__(
".text\n"
".p2align 2\n"
".globl " ASM_SYM(value_landing_pad) "\n"
ASM_SYM(value_landing_pad) ":\n"
"  .cfi_startproc\n"
"  bl " ASM_SYM(catch_value_from_unwind) "\n"
"  ldp x29, x30, [sp], #16\n"
"  ret\n"
"  .cfi_endproc\n"
);

__asm__(
".text\n"
".p2align 2\n"
".globl " ASM_SYM(io_landing_pad) "\n"
ASM_SYM(io_landing_pad) ":\n"
"  .cfi_startproc\n"
"  bl " ASM_SYM(catch_io_from_unwind) "\n"
"  ldp x29, x30, [sp], #16\n"
"  ret\n"
"  .cfi_endproc\n"
);

__asm__(
".text\n"
".p2align 2\n"
".globl " ASM_SYM(default_landing_pad) "\n"
ASM_SYM(default_landing_pad) ":\n"
"  .cfi_startproc\n"
"  bl " ASM_SYM(catch_default_from_unwind) "\n"
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

  const kindNames: array[ThrowKind, string] = ["value", "io"]

  var keep_alive*: seq[ref CatchableError]
  var catch_counts*: array[ThrowKind, int]

  proc catchValueBlock(exc: ref ValueError) =
    inc catch_counts[tkValue]
    echo "catch(ValueError): " & exc.msg

  proc catchIoBlock(exc: ref IOError) =
    inc catch_counts[tkIo]
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

  proc catchValueFromUnwind(exc: pointer)
      {.cdecl, exportc: "catch_value_from_unwind", noinline.} =
    let nim_exc = cast[ref CatchableError](getNimExcFromUnwind(exc))
    if nim_exc of ValueError:
      catchValueBlock(cast[ref ValueError](nim_exc))
    else:
      echo "catch(value-mismatch): " & nim_exc.msg
    deleteUnwindExc(exc)

  proc catchIoFromUnwind(exc: pointer)
      {.cdecl, exportc: "catch_io_from_unwind", noinline.} =
    let nim_exc = cast[ref CatchableError](getNimExcFromUnwind(exc))
    if nim_exc of IOError:
      catchIoBlock(cast[ref IOError](nim_exc))
    else:
      echo "catch(io-mismatch): " & nim_exc.msg
    deleteUnwindExc(exc)

  proc catchDefaultFromUnwind(exc: pointer)
      {.cdecl, exportc: "catch_default_from_unwind", noinline.} =
    let nim_exc = cast[ref CatchableError](getNimExcFromUnwind(exc))
    echo "catch(default): " & nim_exc.msg
    deleteUnwindExc(exc)

  proc runOuter(kind: ThrowKind) =
    let before = catch_counts[kind]
    runDemoTryFrame(cint(kind))
    let name = kindNames[kind]
    if catch_counts[kind] == before + 1:
      echo "post(" & name & "): done"
    else:
      echo "post(" & name & "): no exception captured"

when isMainModule:
  when defined(arm64) or defined(aarch64):
    echo "libunwind try/catch from one outer proc:"
    runOuter(tkValue)
    runOuter(tkIo)
    cExit(0)
  else:
    echo "This example is only implemented for AArch64."
