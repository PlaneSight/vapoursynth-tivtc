"""
Issue #8: TFM "Explicitly instantiated a Cache" warning on VS R58+.
https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/8

Fix: remove explicit std.Cache instantiation when PP > 4.
VapourSynth's scheduler handles caching automatically.
"""
import pytest
from .vspipe_helpers import PLUGIN, vspipe_info, vspipe_frame_count


TFM_CACHE_VPY = f"""
import vapoursynth as vs
core = vs.core
core.std.LoadPlugin(r'{PLUGIN}')

clip = core.std.BlankClip(width=640, height=480, format=vs.YUV420P8,
                          length=10, fpsnum=30000, fpsden=1001)
clip = core.std.SetFrameProps(clip, _FieldBased=vs.FIELD_TOP)
tfm = clip.tivtc.TFM()
tfm.set_output()
"""

TFM_CACHE_PP7_VPY = f"""
import vapoursynth as vs
core = vs.core
core.std.LoadPlugin(r'{PLUGIN}')

clip = core.std.BlankClip(width=640, height=480, format=vs.YUV420P8,
                          length=10, fpsnum=30000, fpsden=1001)
clip = core.std.SetFrameProps(clip, _FieldBased=vs.FIELD_TOP)
tfm = clip.tivtc.TFM(PP=7)
tfm.set_output()
"""


def test_tfm_no_cache_error():
    """TFM with default PP should process via vspipe without error."""
    info = vspipe_info(TFM_CACHE_VPY)
    assert info["numFrames"] == 10


def test_tfm_pp_above_4_no_cache_error():
    """PP=7 was the trigger for explicit Cache — must not error."""
    info = vspipe_info(TFM_CACHE_PP7_VPY)
    assert info["numFrames"] == 10
