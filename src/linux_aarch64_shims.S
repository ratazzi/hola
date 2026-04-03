// Provide sigsetjmp symbol for aarch64-linux cross-compilation.
// OpenSSL armcap.c references sigsetjmp directly for CPU feature probing.
// Glibc defines sigsetjmp as a macro expanding to __sigsetjmp, but the
// pre-compiled libcrypto.a references the sigsetjmp symbol.
// Tail-call to __sigsetjmp so the caller's registers are saved correctly.

#if defined(__aarch64__) && defined(__linux__)
.global sigsetjmp
.type sigsetjmp, @function
sigsetjmp:
    b __sigsetjmp
.size sigsetjmp, .-sigsetjmp
#endif
