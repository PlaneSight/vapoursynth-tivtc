"""
Issue #4: TDecimate mode=2 crashes.
https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/4

Fix: serialize TDecimate mode 2 (fmSerial + nfMakeLinear) since it uses
a state machine tracking prev/curr/next cycles across frame requests.
Also fixed the requestFrameFilter calls in the arInitial path to use
proper bounds (std::max(0, std::min(i, vi_child->numFrames - 1))).
"""
import vapoursynth as vs
import pytest
from .helpers import make_interlaced_test_clip


def test_mode2_no_crash(core):
    """TDecimate mode=2 should not crash or raise when requesting output frames."""
    clip = make_interlaced_test_clip(
        core, width=640, height=480, length=120,
        fpsnum=30000, fpsden=1001,
    )

    tfm_clip = clip.tivtc.TFM()
    for i in range(0, min(30, tfm_clip.num_frames)):
        tfm_clip.get_frame(i)

    try:
        decimated = tfm_clip.tivtc.TDecimate(mode=2, rate=23.976)
        for i in range(0, min(10, decimated.num_frames)):
            f = decimated.get_frame(i)
            assert f is not None, f"Frame {i} is None"
    except Exception as e:
        pytest.fail(f"TDecimate mode=2 raised: {e}")


def test_mode2_reduces_frame_count(core):
    """Mode 2 with rate=23.976 should reduce frame count from 30fps input."""
    clip = make_interlaced_test_clip(
        core, width=320, height=240, length=100,
        fpsnum=30000, fpsden=1001,
    )

    tfm_clip = clip.tivtc.TFM()
    for i in range(0, min(30, tfm_clip.num_frames)):
        tfm_clip.get_frame(i)

    decimated = tfm_clip.tivtc.TDecimate(mode=2, rate=23.976)
    assert 0 < decimated.num_frames < clip.num_frames, (
        f"Mode 2 should reduce frame count from {clip.num_frames}, "
        f"got {decimated.num_frames}"
    )
    # Request a few output frames to exercise the full decode path
    for i in range(0, min(5, decimated.num_frames)):
        f = decimated.get_frame(i)
        assert f is not None, f"Frame {i} is None"
