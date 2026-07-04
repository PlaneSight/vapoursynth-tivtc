# pytest configuration for tivtc regression tests
import pytest
import vapoursynth as vs
from .helpers import PLUGIN


@pytest.fixture(scope="session")
def core():
    """Load tivtc plugin into VS core (idempotent across files via session scope)."""
    c = vs.core
    try:
        c.std.LoadPlugin(str(PLUGIN))
    except vs.Error as e:
        if "already loaded" not in str(e):
            raise
    return c


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "slow: marks tests as slow (deselect with '-m \"not slow\"')"
    )
