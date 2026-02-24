
Option 2 is actually how most language runtimes handle this in practice. The idea is to keep the asm surface area as small as possible — just enough to capture the ABI-defined register state and forward it into C.
What the ABI Guarantees at Landing Pad Entry
When libunwind installs a context via _URC_INSTALL_CONTEXT, it restores all the registers it saved during unwinding, plus whatever you set via _Unwind_SetGR. On x86-64 Itanium ABI:

rax (__builtin_eh_return_data_regno(0)) — pointer to _Unwind_Exception
rdx (__builtin_eh_return_data_regno(1)) — selector (which catch clause matched, or 0 for cleanup)

So when execution arrives at your landing pad address, those two registers hold everything you need. The stack is also in a valid state for the frame that owns the landing pad.
The Trampoline Pattern
asm; landing_pad.S
.globl my_landing_pad
my_landing_pad:
    ; rax = _Unwind_Exception*, rdx = selector
    ; Move into C calling convention (System V AMD64 ABI: rdi, rsi)
    mov  %rax, %rdi
    mov  %rdx, %rsi
    jmp  my_landing_pad_c   ; tail call — no stack frame needed
And the C side:
c// exception_handler.c

#include <unwind.h>
#include <stdint.h>

typedef struct {
    struct _Unwind_Exception unwind_info;
    void *thrown_object;
} MyException;

void my_landing_pad_c(struct _Unwind_Exception *exc, int64_t selector) {
    MyException *my_exc = (MyException *)exc;

    if (selector == 0) {
        // cleanup only (scope exit, destructors)
        run_cleanups();
        _Unwind_Resume(exc);  // continue unwinding to real handler
    } else {
        // actual catch — selector tells you which handler matched
        handle_exception(my_exc->thrown_object, selector);
    }
}
The jmp instead of call is important — it keeps the stack frame consistent with what the unwinder saved. If you used call, you'd push a return address and misalign the frame relative to what the CFI data describes.
Registering the Landing Pad Address
Your personality function needs to know where my_landing_pad lives so it can pass it to _Unwind_SetIP. You can get this in C cleanly:
c// forward declaration of asm symbol
extern void my_landing_pad(void);

// in personality function, cleanup phase:
_Unwind_SetIP(context, (uintptr_t)&my_landing_pad);
No magic needed — it's just a symbol.
Handling Multiple Landing Pads / Selectors
If you have multiple try blocks or catch types, you have a few approaches:
Single trampoline, selector-based dispatch — one landing pad, the selector value tells the C handler which catch clause was matched. This is what C++ compilers do. The LSDA maps call sites to (landing pad, selector) pairs.
Per-scope trampolines — a unique landing pad symbol per try block. Simpler logic but more asm. Usually not worth it.
In practice, the single-trampoline approach works well. You store enough context (in a thread-local or in the exception object itself) so the C handler can reconstruct what it needs from the selector alone.
The CFI Annotations
For the trampoline to be safe — especially if an exception could propagate through the landing pad itself — you need CFI annotations:
asmmy_landing_pad:
    .cfi_startproc
    .cfi_undefined rip      ; we didn't arrive here via call, no return address
    mov  %rax, %rdi
    mov  %rdx, %rsi
    jmp  my_landing_pad_c
    .cfi_endproc
```

`.cfi_undefined rip` tells the unwinder "there's no return address on the stack here" which is correct — you jumped here, not called. Without this, a secondary exception during cleanup could corrupt the unwind info and crash or silently do the wrong thing.

## A Minimal Working Sketch

Putting it together, the full flow looks like:
```
throw()
  → _Unwind_RaiseException()
    → Phase 1: personality walks stack, finds handler, returns _URC_HANDLER_FOUND
    → Phase 2: personality sets IP = &my_landing_pad, returns _URC_INSTALL_CONTEXT
      → libunwind restores registers, jumps to my_landing_pad
        → 3 asm instructions move rax/rdx → rdi/rsi, tail-call into C
          → my_landing_pad_c() does everything else in C
The asm shim ends up being literally 3 instructions. Everything interesting — LSDA parsing, type matching, cleanup sequencing, _Unwind_Resume — lives in C. This is a very comfortable division of labor and is essentially how LDC's and GDC's runtime exception glue works under the hood.


