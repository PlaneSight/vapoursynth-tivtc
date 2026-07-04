// Stub x86 SSE header for non-x86 builds.
// This project requires x86 SIMD intrinsics at compile time,
// guarded by VS_TARGET_CPU_X86. On ARM we provide minimal stubs
// so the C-only code paths (USE_C_NO_ASM) can compile.
#pragma once
#ifndef __SSE__
#define __SSE__ 1
#endif
typedef long long __m64;
typedef long long __m128i __attribute__((__vector_size__(16)));
typedef float __m128 __attribute__((__vector_size__(16)));
typedef double __m128d __attribute__((__vector_size__(16)));
typedef int __v4si __attribute__((__vector_size__(16)));
typedef short __v8hi __attribute__((__vector_size__(16)));
typedef char __v16qi __attribute__((__vector_size__(16)));
typedef long long __v2di __attribute__((__vector_size__(16)));
typedef float __v4sf __attribute__((__vector_size__(16)));
static __inline__ __m64 __attribute__((__always_inline__)) _mm_setzero_si64(void) { return (__m64){}; }
static __inline__ void __attribute__((__always_inline__)) _mm_empty(void) {}
