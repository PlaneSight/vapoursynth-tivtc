// Stub SSE2 header for non-x86 builds.
// Included by TCommonASM.h for runtime feature checks.
// The actual SIMD code paths are gated by CPU feature checks
// and bypassed via USE_C_NO_ASM.
#pragma once
#include "xmmintrin.h"
