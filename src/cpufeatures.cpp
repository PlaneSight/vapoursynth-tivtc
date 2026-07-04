/*
* Copyright (c) 2012-2019 Fredrik Mellbin
*
* This file is part of VapourSynth.
*
* VapourSynth is free software; you can redistribute it and/or
* modify it under the terms of the GNU Lesser General Public
* License as published by the Free Software Foundation; either
* version 2.1 of the License, or (at your option) any later version.
*
* VapourSynth is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* Lesser General Public License for more details.
*
* You should have received a copy of the GNU Lesser General Public
* License along with VapourSynth; if not, write to the Free Software
* Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
*/

#include <string.h>

#include "cpufeatures.h"

#ifdef VS_TARGET_CPU_X86

#ifdef _MSC_VER
#include <intrin.h>
#else
#include <cpuid.h>
#endif

static void vs_cpu_cpuid(int index, int* eax, int* ebx, int* ecx, int* edx) {
    *eax = 0;
    *ebx = 0;
    *ecx = 0;
    *edx = 0;
#ifdef _MSC_VER
    int regs[4];
    __cpuidex(regs, index, 0);
    *eax = regs[0];
    *ebx = regs[1];
    *ecx = regs[2];
    *edx = regs[3];
#elif defined(__GNUC__)
    __cpuid_count(index, 0, *eax, *ebx, *ecx, *edx);
#else
#error "Unknown compiler, can't get cpuid"
#endif
}

static unsigned long long vs_cpu_xgetbv(unsigned ecx) {
#if defined(_MSC_VER)
    return _xgetbv(ecx);
#elif defined(__GNUC__)
    unsigned eax, edx;
    __asm("xgetbv" : "=a"(eax), "=d"(edx) : "c"(ecx) : );
    return (((unsigned long long)edx) << 32) | eax;
#else
    return 0;
#endif
}

static CPUFeatures cpuFeatures;

static void detectCPUFeatures(void) {
    memset(&cpuFeatures, 0, sizeof(CPUFeatures));

    int info[4];
    vs_cpu_cpuid(0, &info[0], &info[1], &info[2], &info[3]);
    int nIds = info[0];

    vs_cpu_cpuid(1, &info[0], &info[1], &info[2], &info[3]);
    cpuFeatures.sse2 = (info[3] & (1 << 26)) ? 1 : 0;
    cpuFeatures.sse3 = (info[2] & (1 << 0)) ? 1 : 0;
    cpuFeatures.ssse3 = (info[2] & (1 << 9)) ? 1 : 0;
    cpuFeatures.fma3 = (info[2] & (1 << 12)) ? 1 : 0;
    cpuFeatures.f16c = (info[2] & (1 << 29)) ? 1 : 0;
    cpuFeatures.movbe = (info[2] & (1 << 22)) ? 1 : 0;
    cpuFeatures.popcnt = (info[2] & (1 << 23)) ? 1 : 0;
    cpuFeatures.aes = (info[2] & (1 << 25)) ? 1 : 0;
    cpuFeatures.sse4_1 = (info[2] & (1 << 19)) ? 1 : 0;
    cpuFeatures.sse4_2 = (info[2] & (1 << 20)) ? 1 : 0;
    cpuFeatures.avx = 0;

    if (info[2] & (1 << 27)) {
        // osxsave
        unsigned long long xcrFeatureMask = vs_cpu_xgetbv(0);
        if ((xcrFeatureMask & 6) == 6) {
            cpuFeatures.avx = (info[2] & (1 << 28)) ? 1 : 0;
            cpuFeatures.avx2 = 0;
            if (nIds >= 7) {
                vs_cpu_cpuid(7, &info[0], &info[1], &info[2], &info[3]);
                cpuFeatures.avx2 = (info[1] & (1 << 5)) ? 1 : 0;
                cpuFeatures.avx512_f = (info[1] & (1 << 16)) ? 1 : 0;
                cpuFeatures.avx512_cd = (info[1] & (1 << 28)) ? 1 : 0;
                cpuFeatures.avx512_bw = (info[1] & (1 << 30)) ? 1 : 0;
                cpuFeatures.avx512_dq = (info[1] & (1 << 17)) ? 1 : 0;
                cpuFeatures.avx512_vl = (info[1] & (1 << 31)) ? 1 : 0;
            }
        }
    }
}

#else // !VS_TARGET_CPU_X86

static CPUFeatures cpuFeatures;

static void detectCPUFeatures(void) {
    memset(&cpuFeatures, 0, sizeof(CPUFeatures));
}

#endif // VS_TARGET_CPU_X86

const CPUFeatures *getCPUFeatures(void) {
    static int initialized = 0;
    if (!initialized) {
        detectCPUFeatures();
        initialized = 1;
    }
    return &cpuFeatures;
}
