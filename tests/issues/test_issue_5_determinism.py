"""
Issue #5: TFM results are not deterministic.
https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/5

Fix: switch TFM from fmParallelRequests to fmSerial. TFM's GetFrame
uses shared scratch buffers (cArray, tbuffer, cmask, map) allocated
once in the constructor and reused across all frame requests. It also
mutates tracking state (lastMatch, sclast). With concurrent access,
these were corrupted between arAllFramesReady invocations.
"""
import numpy as np
import vapoursynth as vs
import pytest
from .helpers import frame_as_array, make_interlaced_test_clip


def test_tfm_deterministic(core):
    """Two TFM runs on the same clip must produce pixel-identical output."""
    clip = make_interlaced_test_clip(
        core, width=640, height=480, length=30,
        fpsnum=30000, fpsden=1001,
    )

    run1 = clip.tivtc.TFM(mode=0, cthresh=6, MI=64)
    run2 = clip.tivtc.TFM(mode=0, cthresh=6, MI=64)

    for n in range(run1.num_frames):
        f1 = run1.get_frame(n)
        f2 = run2.get_frame(n)

        for plane in range(f1.format.num_planes):
            p1 = frame_as_array(f1, plane)
            p2 = frame_as_array(f2, plane)
            if not np.array_equal(p1, p2):
                diff = np.abs(p1.astype(int) - p2.astype(int))
                pytest.fail(
                    f"Frame {n} plane {plane}: non-deterministic!\n"
                    f"Max diff: {diff.max()}, non-zero: {np.count_nonzero(diff)}"
                )


def test_combed_props_deterministic(core):
    """_Combed frame props must match across runs."""
    clip = make_interlaced_test_clip(
        core, width=640, height=480, length=30,
        fpsnum=30000, fpsden=1001,
    )

    run1 = clip.tivtc.TFM(mode=0, cthresh=6, MI=64)
    run2 = clip.tivtc.TFM(mode=0, cthresh=6, MI=64)

    for n in range(run1.num_frames):
        c1 = run1.get_frame(n).props.get('_Combed', -1)
        c2 = run2.get_frame(n).props.get('_Combed', -1)
        assert c1 == c2, f"Frame {n}: _Combed={c1} vs {c2}"
