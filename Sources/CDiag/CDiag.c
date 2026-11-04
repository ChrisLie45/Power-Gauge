// The kernel's diagnostic call, which is where powermetrics gets its CPU power samples: x86_64
// system call class 4 (SYSCALL_CLASS_DIAG), handled by diagCall64 in xnu's
// osfmk/i386/Diagnostics.c, with the selector in rdi and a buffer in rsi. A selector the kernel
// does not know raises EXC_SYSCALL, which ends the process, so the app makes its first call in
// a child process (see KernelStats.open).

#include "CDiag.h"

long powergauge_diag(long selector, void *buffer) {
#if defined(__x86_64__)
    long result;
    __asm__ volatile("syscall"
                     : "=a"(result)
                     : "a"(4L << 24), "D"(selector), "S"(buffer)
                     : "rcx", "r11", "memory");
    return result;
#else
    (void)selector;
    (void)buffer;
    return -1;
#endif
}
