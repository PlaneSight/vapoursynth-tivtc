"""
Issue #3: TFM y0/y1 vertical band exclusion not functioning.
https://github.com/dubhatervapoursynth/vapoursynth-tivtc/issues/3

Fix: zero cmask rows in [y0,y1) range after comb analysis so they don't
contribute to the MIC computation. Fixes cases like head-switching noise
on VHS captures where cropping before TFM worked but y0/y1 didn't.
"""
import vapoursynth as vs
import pytest
from .helpers import frame_as_array, make_blank_fieldbased


def test_exclusion_band_suppresses_combing(core):
    """Frames with comb-like noise in the excluded band should NOT be flagged as combed."""
    base = make_blank_fieldbased(core, width=640, height=480, length=30)

    def make_noisy_frame(n, f):
        fout = f.copy()
        arr = frame_as_array(fout, 0, writable=True)
        for row in range(100, 110):
            arr[row, :] = 16 if (row % 2) == 0 else 235
        return fout

    noisy = core.std.ModifyFrame(base, base, make_noisy_frame)

    # Without exclusion: should detect combing
    tfm_no_exclude = noisy.tivtc.TFM(mode=0, cthresh=6, MI=64)
    combed_no = tfm_no_exclude.get_frame(0).props.get('_Combed', -1)
    assert combed_no == 1, f"Without exclusion, expected _Combed=1, got {combed_no}"

    # With exclusion band covering the noise: should NOT detect combing
    tfm_excluded = noisy.tivtc.TFM(mode=0, cthresh=6, MI=64, y0=100, y1=110)
    combed_yes = tfm_excluded.get_frame(0).props.get('_Combed', -1)
    assert combed_yes == 0, (
        f"With y0=100 y1=110, expected _Combed=0, got {combed_yes}"
    )


def test_y0y1_defaults_no_error(core):
    """y0=y1=0 should be accepted without error."""
    clip = make_blank_fieldbased(core, length=10)
    result = clip.tivtc.TFM(y0=0, y1=0, order=1)
    assert result.format.id == clip.format.id
    assert result.num_frames == clip.num_frames
    # Must actually request a frame to exercise the GetFrame path
    f = result.get_frame(0)
    assert f is not None
