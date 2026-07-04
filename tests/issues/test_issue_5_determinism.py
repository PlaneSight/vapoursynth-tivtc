"""
Issue #5: TFM results are not deterministic.
https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/5

Fix: switch TFM from fmParallelRequests to fmSerial. TFM's GetFrame
uses shared scratch buffers (cArray, tbuffer, cmask, map) that are
not thread-safe. With fmParallelRequests, concurrent arAllFramesReady
invocations corrupt the shared buffers causing non-deterministic output.

vspipe with --requests > 1 exercises the multi-threaded code path:
two runs with identical input must produce identical pixel output.
"""
import pytest
from .vspipe_helpers import PLUGIN, vspipe_checksum


TFM_DETERM_VPY = f"""
import vapoursynth as vs
core = vs.core
core.std.LoadPlugin(r'{PLUGIN}')

clip = core.std.BlankClip(width=640, height=480, format=vs.YUV420P8,
                          length=30, fpsnum=30000, fpsden=1001,
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
tfm = clip.tivtc.TFM(mode=0, cthresh=6, MI=64)
tfm.set_output()
"""


def test_tfm_deterministic_mt():
    """Two vspipe runs with --requests 4 must produce identical pixel output."""
    run1 = vspipe_checksum(TFM_DETERM_VPY, requests=4, timeout=30)
    run2 = vspipe_checksum(TFM_DETERM_VPY, requests=4, timeout=30)
    assert run1 == run2, (
        f"Non-deterministic output detected!\n"
        f"Run 1 sha256: {run1}\n"
        f"Run 2 sha256: {run2}"
    )


def test_tfm_deterministic_st():
    """Single-threaded runs should also be identical."""
    run1 = vspipe_checksum(TFM_DETERM_VPY, requests=1, timeout=30)
    run2 = vspipe_checksum(TFM_DETERM_VPY, requests=1, timeout=30)
    assert run1 == run2
