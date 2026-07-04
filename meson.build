project('TIVTC', 'cpp',
        version: '1',
        default_options: ['cpp_std=c++17', 'buildtype=release'],
        meson_version: '>=0.46')

warnings = [
  '-Wall',
  '-Wextra',
  '-Wshadow',
  '-Wno-unused-function',
]

cflags = [
  warnings,
  '-fvisibility=hidden',
  '-I' + meson.source_root() + '/vendor/include',
]

ldflags = [
]

host_cpu_family = host_machine.cpu_family()

if host_cpu_family.startswith('x86')
  cflags += ['-mfpmath=sse', '-msse2', '-DVS_TARGET_CPU_X86=1']
else
  message('Building without SIMD assembly (x86-only ASM sources excluded)')
endif

host_system = host_machine.system()

if host_system == 'windows' or host_system == 'cygwin'
  if host_cpu_family == 'x86'
    cflags += '-mstackrealign'
    ldflags += '-Wl,--kill-at'
  endif

  # Avoid linking errors:
  # /usr/lib/gcc/x86_64-w64-mingw32/10.2.0/../../../../x86_64-w64-mingw32/bin/ld: libtivtc.dll.p/src_TFM.cpp.obj:TFM.cpp:(.text+0x9019): undefined reference to `__strcat_chk'
  cflags += ['-U_FORTIFY_SOURCE', '-D_FORTIFY_SOURCE=0']
endif

cxx = meson.get_compiler('cpp')

cxx_id = cxx.get_id()

if cxx_id.startswith('clang')
  cflags += '-DCLANG=1'
endif

if cxx_id == 'gcc'
  cflags += '-DGCC=1'
endif

common_sources = [
  'src/calcCRC.cpp',
  'src/cpufeatures.cpp',
  'src/Cycle.cpp',
  'src/PluginInit.cpp',
  'src/TDecimate.cpp',
  'src/TDecimateBlur.cpp',
  'src/TDecimateMode2.cpp',
  'src/TDecimateMode7.cpp',
  'src/TDecimateOut.cpp',
  'src/TFM.cpp',
  'src/TFMD2V.cpp',
  'src/TFMPlanar.cpp',
]

# ASM-optimized implementations (x86 SSE only)
asm_sources = [
  'src/TCommonASM.cpp',
  'src/TDecimateASM.cpp',
  'src/TFMASM.cpp',
  'src/TFMPP.cpp',
]

if host_cpu_family.startswith('x86')
  sources = common_sources + asm_sources
else
  sources = common_sources
endif

deps = [
  dependency('vapoursynth').partial_dependency(includes: true, compile_args: true),
]

shared_module('tivtc',
              sources,
              dependencies: deps,
              link_args: ldflags,
              cpp_args: cflags,
              install: true)
