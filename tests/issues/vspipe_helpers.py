"""
VapourSynth scripting helpers for vspipe-based tests.
Writes temporary .vpy scripts and runs them via vspipe.
"""
import subprocess
import tempfile
import os
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
PLUGIN = REPO / "build-cpp" / "libtivtc.dylib"
VSPIPE = "vspipe"


def _load_plugin(core_fn: str) -> str:
    """Return the VapourSynth Python preamble to load tivtc."""
    return f"""
import vapoursynth as vs
core = vs.core
core.std.LoadPlugin(r'{PLUGIN}')
{core_fn}
"""


def run_vpy(script: str, *args, timeout: int = 30) -> subprocess.CompletedProcess:
    """Write script to a temp .vpy, run vspipe with args, return result."""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".vpy", delete=False, dir=REPO / "tests"
    ) as f:
        f.write(script)
        tmp = f.name
    try:
        return subprocess.run(
            [VSPIPE] + list(args) + [tmp, "-"],
            capture_output=True, text=True, timeout=timeout,
            cwd=REPO / "tests",
        )
    finally:
        os.unlink(tmp)


def vspipe_info(script: str, timeout: int = 15) -> dict:
    """Run `vspipe --info` and parse the text output into a dict."""
    proc = run_vpy(script, "--info", timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(f"vspipe --info failed:\n{proc.stderr}")
    info = {}
    for line in proc.stdout.strip().split("\n"):
        if ": " in line:
            k, v = line.split(": ", 1)
            info[k.strip()] = v.strip()
    info["numFrames"] = int(info.get("Frames", 0))
    info["formatName"] = info.get("Format Name", "")
    return info


def vspipe_frames(script: str, requests: int = 1, timeout: int = 30) -> bytes:
    """Run vspipe to raw video, return stdout bytes (pixel data)."""
    proc = subprocess.run(
        [VSPIPE, "--requests", str(requests), "-c", "y4m", "-", "-"],
        input=script.encode(), capture_output=True, timeout=timeout,
        cwd=REPO / "tests",
    )
    if proc.returncode != 0:
        raise RuntimeError(f"vspipe failed:\n{proc.stderr.decode()}")
    return proc.stdout


def vspipe_checksum(script: str, requests: int = 1, timeout: int = 30) -> str:
    """Run `vspipe --requests N -c y4m | shasum -a 256` and return hex digest."""
    import hashlib
    data = vspipe_frames(script, requests=requests, timeout=timeout)
    return hashlib.sha256(data).hexdigest()


def vspipe_frame_count(script: str, requests: int = 1, timeout: int = 30) -> int:
    """Return the number of output frames."""
    info = vspipe_info(script, timeout=timeout)
    return info.get("numFrames", 0)
