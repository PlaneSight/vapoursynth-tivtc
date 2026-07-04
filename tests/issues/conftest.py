# pytest configuration for tivtc regression tests (vspipe-based)
import pytest


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "slow: marks tests as slow (deselect with '-m \"not slow\"')"
    )
