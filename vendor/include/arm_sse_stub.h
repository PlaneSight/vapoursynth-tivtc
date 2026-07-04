// ARM SSE stub — prevents vendor x86 SSE headers from loading on non-x86.
// Define header guards BEFORE the vendor headers can set them.
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
