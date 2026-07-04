#pragma once
// ARM SSE stub — prevents vendor x86 SSE headers from loading on non-x86.
#define _XMMINTRIN_H
#define _EMMINTRIN_H  
#define _SMMINTRIN_H

#include <cstdint>

typedef long long __m128i __attribute__((__vector_size__(16)));
typedef float __m128 __attribute__((__vector_size__(16)));
typedef double __m128d __attribute__((__vector_size__(16)));

inline __m128i _mm_set1_epi8(char) { return __m128i{}; }
inline __m128i _mm_set1_epi16(short) { return __m128i{}; }
inline __m128i _mm_set1_epi32(int) { return __m128i{}; }
inline __m128i _mm_load_si128(const __m128i*) { return __m128i{}; }
inline void _mm_store_si128(__m128i*, __m128i) {}
inline __m128i _mm_subs_epu8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_subs_epu16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_or_si128(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_adds_epu8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_adds_epu16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_cmpeq_epi8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_xor_si128(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_and_si128(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_srli_si128(__m128i, int) { return __m128i{}; }
inline __m128i _mm_slli_si128(__m128i, int) { return __m128i{}; }
inline __m128i _mm_srli_epi16(__m128i, int) { return __m128i{}; }
inline __m128i _mm_unpacklo_epi8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_unpackhi_epi8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_unpacklo_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_unpackhi_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_add_epi32(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_add_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_sub_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_sad_epu8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_mulhi_epu16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_packus_epi16(__m128i, __m128i) { return __m128i{}; }
inline int _mm_extract_epi16(__m128i, int) { return 0; }
inline int _mm_cvtsi128_si32(__m128i) { return 0; }
inline __m128i _mm_setzero_si128() { return __m128i{}; }
inline __m128i _mm_cvtsi32_si128(int) { return __m128i{}; }
inline __m128i _mm_loadl_epi64(const __m128i*) { return __m128i{}; }
inline void _mm_storel_epi64(__m128i*, __m128i) {}
inline __m128i _mm_cmpeq_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_slli_epi32(__m128i, int) { return __m128i{}; }
inline __m128i _mm_srli_epi32(__m128i, int) { return __m128i{}; }
inline __m128i _mm_unpacklo_epi32(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_unpackhi_epi32(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_add_epi8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_sub_epi8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_sub_epi32(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_abs_epi16(__m128i) { return __m128i{}; }
inline __m128i _mm_abs_epi32(__m128i) { return __m128i{}; }
inline __m128i _mm_max_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_min_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_packs_epi32(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_madd_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128d _mm_castsi128_pd(__m128i) { return __m128d{}; }
inline __m128d _mm_load_sd(const double*) { return __m128d{}; }
inline __m128i _mm_add_epi64(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_andnot_si128(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_blendv_epi8(__m128i, __m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_cvtepi8_epi16(__m128i) { return __m128i{}; }
inline __m128 _mm_load_ss(const float*) { return __m128{}; }
inline __m128i _mm_max_epu16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_min_epu16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_min_epu8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_mullo_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_mullo_epi32(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_slli_epi16(__m128i, int) { return __m128i{}; }
inline __m128i _mm_subs_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_max_epu8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_cmpgt_epi32(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_avg_epu8(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_avg_epu16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_packs_epi16(__m128i, __m128i) { return __m128i{}; }
inline __m128i _mm_srai_epi32(__m128i, int) { return __m128i{}; }
inline __m128i _mm_castps_si128(__m128) { return __m128i{}; }
inline __m128i _mm_packus_epi32(__m128i, __m128i) { return __m128i{}; }
