# vapoursynth-tivtc

> **Fork of [dubhatervapoursynth/vapoursynth-tivtc](https://github.com/dubhatervapoursynth/vapoursynth-tivtc)** with fixes for outstanding issues.

Field matching (TFM) and decimation (TDecimate) filters for VapourSynth — a port of [tritical's TIVTC](https://github.com/pinterf/TIVTC) for AviSynth.

Provides inverse telecine (IVTC) via field matching followed by decimation of duplicate frames.

## Fixes applied

- [#3](https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/3) — **y0/y1 exclusion**: zero comb mask rows in the excluded band so head-switching noise etc. don't trigger combed-frame detection.
- [#4](https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/4) — **TDecimate mode 2 crash**: serialize the mode 2 state machine (`fmSerial` + `nfMakeLinear`) and fix off-by-one frame request bounds.
- [#5](https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/5) — **Non-deterministic output**: switch TFM from `fmParallelRequests` to `fmSerial` — shared scratch buffers and tracking state are not thread-safe.
- [#8](https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/8) — **Cache warning on VS R58+**: remove explicit `std.Cache` instantiation; VapourSynth's scheduler handles caching automatically.
- High-bit-depth mask support and ARM (aarch64) builds.

Reproducible regression tests under [`tests/issues/`](tests/issues/).

## Build

### Requirements

- C++17 compiler (MSVC, GCC, Clang)
- [Meson](https://mesonbuild.com/) >= 0.46
- [VapourSynth](https://www.vapoursynth.com/) SDK headers (available via `pkg-config` or `vapoursynth.pc`)

### x86/x86_64

```sh
meson setup build
ninja -C build
sudo ninja -C build install
```

### ARM (aarch64) — macOS / Linux

```sh
meson setup build
ninja -C build
```

ARM builds use C-only code paths with SSE intrinsic stubs from `vendor/include_arm/`. Set `-DUSE_C_NO_ASM` is automatic via meson.

---

## TFM — Field Matching

Matches fields from a telecined source to reconstruct progressive frames. The core IVTC field-matching filter.

**Usage:**
```python
clip = core.tivtc.TFM(clip=clip, order=1, mode=1, PP=6)
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `clip` | clip | required | Input clip (8-bit planar YUV only) |
| `order` | int | *auto* | Field order: `0` = bottom‑field first, `1` = top‑field first. Auto‑detects from `_FieldBased` frame property if available. |
| `field` | int | *order* | Field to match: `0` = bottom, `1` = top. Defaults to `order`. |
| `mode` | int | `1` | Matching mode (see below) |
| `PP` | int | `6` | Post‑processing mode for combed frames (see below) |
| `MI` | int | `80` | Motion‑induced‑combing threshold. Higher = more tolerant. Range 0–255. |
| `cthresh` | int | `9` | Combing detection sensitivity. 6–12 typical. Lower = more sensitive. |
| `chroma` | bool | `false` | Include chroma planes in comb detection |
| `blockx` / `blocky` | int | `16` | Block size for comb detection (4, 8, 16, 32). |
| `y0` / `y1` | int | `0` | Exclude vertical band [y0, y1) from comb detection. `y0=471, y1=480` excludes head‑switching noise at the bottom of VHS captures. |
| `scthresh` | float | `12.0` | Scene change threshold. |
| `mthresh` | int | `5` | Post‑processing combing threshold for TFMPP. |
| `slow` | int | `1` | `0` = fast field comparison, `1` = slower but more accurate. |
| `mChroma` | bool | `true` | Use chroma in MIC (motion‑induced‑combing) calculation. |
| `cNum` | int | `15` | Consecutive combed frame counter threshold for outputC. |
| `micout` | int | `0` | MIC output detail level: `1` = 3 metrics (p/c/n), `2` = 5 metrics (p/c/n/b/u). |
| `micmatching` | int | `1` | MIC‑based match refinement: `0` = off, `1` = standard, `2` = mode‑specific, `3` = both. |
| `mmsco` | bool | `true` | Require scene change for MIC‑based match override. |
| `ubsco` | bool | `true` | Require scene change for unmatched‑field fallback (u/b). |
| `flags` | int | `4` | Scene change detection flags. `4` = use scene change filter, `5` = also match order. |
| `metric` | int | `0` | Comb detection metric: `0` = standard, `1` = squared (faster). |
| `hint` | bool | `true` | Write hint data as frame properties for TDecimate. |
| `opt` | int | `4` | CPU optimizations: `0` = C only, `1` = MMX, `2` = ISSE, `3` = SSE2, `4` = auto. |
| `display` | bool | `false` | Overlay debug info via `std.FrameEval` + `text.Text`. |
| `clip2` | clip | — | Secondary clip for post‑processing (e.g. deinterlaced version). |
| `ovr` | data | — | Override file path. |
| `input` | data | — | Input metrics file path (reuse from previous run). |
| `output` | data | — | Output metrics file path. |
| `outputC` | data | — | Output combed frame ranges file. |
| `d2v` | data | — | D2V project file for DVD source. |
| `trimIn` | data | — | Trim specification. |
| `debug` | bool | false | Enable debug output (currently unused). |

### Matching modes

| Mode | Description |
|------|-------------|
| `0` | Match only `c` — return weaved `c` frame. No fallback. |
| `1` | Match `p/c/n` — try `p`, then `c`, then `n`. Default. |
| `2` | Match `p/c/u` — try `p`, then `c`, then `u`. |
| `3` | Match `p/c/n` with `u/b` fallback. |
| `4` | Match `p/c/n` — return best metric regardless of combing. |
| `5` | Match `p/c/n` — fall back through `u/b` if combed, then best of remaining. |
| `6` | Match `p/c/n/b/u` — exhaustive search. |
| `7` | Single‑field matching for field‑shifted video. Linear access required. |

### Post‑processing (PP) modes

| PP | Description |
|----|-------------|
| `0` | No post‑processing. |
| `1` | Draw combing boxes on detected combed frames. |
| `2`–`4` | Apply TFMPP deinterlacing at increasing strength. |
| `5`–`7` | Same as 2–4 but cache the input for better performance. |

### Frame properties (output)

| Property | Type | Description |
|----------|------|-------------|
| `TFMMatch` | int | Match type used: `0`=p, `1`=c, `2`=n, `3`=b, `4`=u, `5`=l, `6`=h |
| `TFMMics` | int[] | MIC values for each match type (per‑block combing metric) |
| `TFMDisplay` | data | Debug display string (when `display=True`) |
| `_Combed` | int | `0` = not combed, `1` = combed |
| `TFMD2VFilm` | int | D2V film flag |

---

## TDecimate — Frame Decimation

Decimates (drops) duplicate frames after field matching to restore progressive framerate.

**Usage:**
```python
clip = core.tivtc.TDecimate(clip=clip, mode=1, cycleR=1, cycle=5)
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `clip` | clip | required | Input clip (8‑bit planar YUV only) |
| `mode` | int | required | Decimation mode (see below) |
| `cycleR` | int | `2` | Frames to remove per cycle (mode 0/1/3). |
| `cycle` | int | `5` | Frames per cycle (mode 0/1). Typically 5 for 3:2 pulldown IVTC. |
| `rate` | float | — | Target framerate (modes 2/7). |
| `dupThresh` | float | `1.9` | Duplicate detection threshold (%). |
| `vidThresh` | float | `2.9` | Video detection threshold (%). |
| `sceneThresh` | float | `15.0` | Scene change detection threshold. |
| `hybrid` | int | `0` | Hybrid handling: `0`=film, `1`=blend down, `2`=blend up, `3`=leave video. |
| `vidDetect` | int | — | Video detection method for hybrid. |
| `blockx` / `blocky` | int | `16` | Block size for metric computation. |
| `chroma` | bool | `false` | Include chroma in metric computation. |
| `nt` | int | `0` | Noise threshold for SAD/SSD. |
| `ssd` | bool | `false` | Use SSD instead of SAD for difference metric. |
| `maxndl` | int | `0` | Maximum numerator‑denominator difference for mode 2. |
| `m2PA` | bool | `false` | Mode 2 preliminary analysis. |
| `display` | bool | `false` | Overlay debug info. |
| `vfrDec` | int | `0` | VFR decimation mode for mode 3: `0`=metric, `1`=string. |
| `tcfv1` | bool | `false` | Output timecode file in v1 format (mode 3/6). |
| `mkvOut` | data | — | Path for MKV timecode output file (mode 3/6). |
| `tfmIn` | data | — | Input metrics file from TFM. |
| `input` | data | — | Precomputed metrics file for 2‑pass. |
| `output` | data | — | Output metrics file. |
| `ovr` | data | — | Override file path. |
| `hint` | bool | `true` | Use TFM hint data from frame properties. |
| `predenoise` | bool | `false` | Apply pre‑denoising before metric calculation. |
| `noblend` | bool | `false` | Don't blend frames in mode 0/1 — drop extras instead. |
| `exPP` | bool | `false` | Extended post‑processing. |
| `orgOut` | data | — | Output file for original frame numbers. |
| `opt` | int | `4` | CPU optimizations (same as TFM). |

### Decimation modes

| Mode | Description |
|------|-------------|
| `0` | Decimate by `cycleR` per `cycle` using string‑matching duplicate detection. |
| `1` | Decimate by `cycleR` per `cycle` using most‑similar metric. **Recommended for standard IVTC.** |
| `2` | Arbitrary framerate decimation. Drops frames to hit `rate` fps exactly. |
| `3` | Single‑pass VFR decimation with MKV timecodes output. |
| `4` | Metric output only — returns unmodified frames with metrics in frame properties. |
| `5` | Two‑pass hybrid analysis (first pass). |
| `6` | 120 fps → VFR with timecodes (second pass). |
| `7` | Arbitrary framerate decimation v2 — alternative to mode 2. |

### Frame properties (output)

| Property | Type | Description |
|----------|------|-------------|
| `TDecimateCycleStart` | int | Frame number of cycle start |
| `TDecimateCycleMaxBlockDiff` | int[] | Maximum block differences per cycle (mode 0/1) |
| `TDecimateOriginalFrame` | int | Original frame number before decimation |
| `TDecimateDisplay` | data | Debug display string (when `display=True`) |
| `_DurationNum` / `_DurationDen` | int | Frame duration for VFR output |

---

## Examples

### Standard 3:2 pulldown IVTC (29.97 → 23.976 fps)

```python
import vapoursynth as vs
core = vs.core

src = core.ffms2.Source("input.mkv")

# Field match
matched = core.tivtc.TFM(clip=src, order=1, mode=1, PP=6)

# Decimate 29.97 → 23.976 (cycleR=1 every cycle=5)
decimated = core.tivtc.TDecimate(clip=matched, mode=1, cycleR=1, cycle=5)

decimated.set_output()
```

### Using arbitrary framerate decimation (mode 2)

```python
matched = core.tivtc.TFM(clip=src, order=1, mode=1, PP=6)
decimated = core.tivtc.TDecimate(clip=matched, mode=2, rate=23.976)
```

### Excluding VHS head-switching noise from TFM decisions

```python
matched = core.tivtc.TFM(clip=src, order=1, y0=471, y1=480)
```

### Two-pass VFR decimation

```python
# Pass 1: metric output
metrics = core.tivtc.TDecimate(clip=matched, mode=4)
metrics = core.std.BlankClip(metrics, length=1)  # force single-frame evaluation

# Pass 2: apply decimation using saved metrics
core.tivtc.TDecimate(clip=matched, mode=5, input="metrics.tdec")
```

---

## Override files

Both filters accept override (`.ovr`) files for frame‑specific control.

### TFM overrides

Format: `frame_number match_type [override_type]`

- `p`, `c`, `n`, `b`, `u` — force match type
- `+` — force combed
- `-` — force clean

### TDecimate overrides

Format: `frame_number [action]`

- `d` — drop frame
- `k` — keep frame
- `f` — film frame
- `v` — video frame
- `mn` — force metric

---

## Known limitations

- **8‑bit planar YUV only** — no 10/12/14/16‑bit, no RGB, no YUY2.
- **x86/x86_64 only** — requires SSE2 at minimum.
- **TFM is serialized** — this is required for deterministic output due to shared internal state (see issue #5).
- TDecimate modes 2 and 7 require linear access (`fmSerial` + `nfMakeLinear`) because of their internal state machines.

## License

GNU General Public License v2.0 or later.

Original AviSynth TIVTC by Kevin Stone (tritical), additional work by pinterf. VapourSynth port by dubhater and contributors.
