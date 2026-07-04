"""
Issue #4: TDecimate mode=2 crashes.
https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/4

Fix: serialize TDecimate mode 2 (fmSerial + nfMakeLinear) since it uses
a state machine tracking prev/curr/next cycles across frame requests.
Also fixed off-by-one requestFrameFilter bounds.
"""
import pytest
from .vspipe_helpers import PLUGIN, vspipe_info, vspipe_frame_count


TDEC_MODE2_VPY = f"""
import vapoursynth as vs
core = vs.core
core.std.LoadPlugin(r'{PLUGIN}')

# Create interlaced-looking clip
clip = core.std.BlankClip(width=640, height=480, format=vs.YUV420P8,
                          length=120, fpsnum=30000, fpsden=1001,
                          color=[128, 128, 128], keep=True)
clip = core.std.SetFrameProps(clip, _FieldBased=vs.FIELD_TOP)

def add_stripes(n, f):
    import numpy as np, ctypes
    fout = f.copy()
    ptr = fout.get_write_ptr(0)
    stride = fout.get_stride(0)
    arr = np.ctypeslib.as_array(
        ctypes.cast(ptr, ctypes.POINTER(ctypes.c_uint8 * (stride * 480))).contents
    ).view(np.uint8).reshape(480, stride)[:, :640]
    for row in range(0, 480, 2):
        if n % 2 == 0:
            arr[row, :] = 200
        elif row + 1 < 480:
            arr[row + 1, :] = 55
    return fout

clip = core.std.ModifyFrame(clip, clip, add_stripes)

# TFM + TDecimate mode 2
tfm = clip.tivtc.TFM()
decimated = tfm.tivtc.TDecimate(mode=2, rate=23.976)
decimated.set_output()
"""


def test_mode2_no_crash():
    """TDecimate mode=2 should process via vspipe without segfault."""
    info = vspipe_info(TDEC_MODE2_VPY, timeout=30)
    assert info["numFrames"] > 0


def test_mode2_reduces_frame_count():
    """30fps -> 24fps should reduce frame count."""
    n = vspipe_frame_count(TDEC_MODE2_VPY, timeout=30)
    assert 0 < n < 120, f"Expected 0 < frames < 120, got {n}"
