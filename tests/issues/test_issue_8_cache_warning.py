"""
Issue #8: TFM "Explicitly instantiated a Cache" warning on VS R58+.
https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/8

Fix: remove explicit std.Cache instantiation when PP > 4. VapourSynth's
scheduler handles caching automatically — explicit Cache nodes were
always non-portable and were disallowed in R58+.
"""
import vapoursynth as vs
import pytest
from .helpers import make_blank_fieldbased


def test_tfm_no_cache_error(core):
    """TFM should create output without error on VS R77 (no Cache warning)."""
    clip = make_blank_fieldbased(core, length=10, fpsnum=30000, fpsden=1001)

    result = clip.tivtc.TFM()
    assert result is not None
    assert result.num_frames == clip.num_frames
    # Actually request frames — the Cache bug manifested during frame processing
    f = result.get_frame(0)
    assert f is not None


def test_tfm_pp_above_4_no_cache_error(core):
    """PP > 4 was the trigger for explicit Cache instantiation — must work."""
    clip = make_blank_fieldbased(core, length=10, fpsnum=30000, fpsden=1001)

    result_pp5 = clip.tivtc.TFM(PP=5)
    assert result_pp5 is not None
    assert result_pp5.num_frames == clip.num_frames
    f5 = result_pp5.get_frame(0)
    assert f5 is not None

    result_pp7 = clip.tivtc.TFM(PP=7)
    assert result_pp7 is not None
    assert result_pp7.num_frames == clip.num_frames
    f7 = result_pp7.get_frame(0)
    assert f7 is not None
