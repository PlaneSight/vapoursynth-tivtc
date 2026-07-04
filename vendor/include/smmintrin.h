// Stub SSE4.1 header for non-x86 builds.
// Included by TCommonASM.cpp, TDecimateASM.cpp, TFMPP.cpp.
// SIMD code is gated by runtime feature checks + USE_C_NO_ASM.
#pragma once
#include "emmintrin.h"
