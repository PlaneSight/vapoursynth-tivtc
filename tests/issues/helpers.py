"""
Shared helpers for tivtc regression tests.
VS API4 frame data access via get_read_ptr / get_write_ptr + ctypes.
"""
import ctypes
import numpy as np
import vapoursynth as vs
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent.parent / "build-cpp" / "libtivtc.dylib"


def frame_as_array(frame, plane=0, writable=False):
    """Return a 2D numpy array view of a VideoFrame plane."""
    if writable:
        ptr = frame.get_write_ptr(plane)
    else:
        ptr = frame.get_read_ptr(plane)
    stride = frame.get_stride(plane)
    h = frame.height
    w = frame.width
    if plane > 0:
        h >>= frame.format.subsampling_h
        w >>= frame.format.subsampling_w
    size = stride * h
    arr = np.ctypeslib.as_array(
        ctypes.cast(ptr, ctypes.POINTER(ctypes.c_uint8 * size)).contents
    ).view(np.uint8).reshape(h, stride)[:, :w]
    return arr


def make_blank_fieldbased(core, width=640, height=480, length=30,
                          fpsnum=24000, fpsden=1001, tff=True):
    """Create a blank clip with _FieldBased prop set for TFM."""
    clip = core.std.BlankClip(
        width=width, height=height, format=vs.YUV420P8,
        length=length, fpsnum=fpsnum, fpsden=fpsden,
        color=[128, 128, 128], keep=True,
    )
    clip = core.std.SetFrameProps(
        clip, _FieldBased=vs.FIELD_TOP if tff else vs.FIELD_BOTTOM
    )
    return clip


def make_interlaced_test_clip(core, width=640, height=480, length=30,
                              fpsnum=30000, fpsden=1001):
    """Create an interlaced-like clip: even/odd frames alternate stripe content."""
    clip = core.std.BlankClip(
        width=width, height=height, format=vs.YUV420P8,
        length=length, fpsnum=fpsnum, fpsden=fpsden,
        color=[128, 128, 128], keep=True,
    )
    clip = core.std.SetFrameProps(clip, _FieldBased=vs.FIELD_TOP)

    def add_stripes(n, f):
        fout = f.copy()
        arr = frame_as_array(fout, 0, writable=True)
        for row in range(0, arr.shape[0], 2):
            if n % 2 == 0:
                arr[row, :] = 200
            elif row + 1 < arr.shape[0]:
                arr[row + 1, :] = 55
        return fout

    return core.std.ModifyFrame(clip, clip, add_stripes)
