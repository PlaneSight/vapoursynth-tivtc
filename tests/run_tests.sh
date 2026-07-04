#!/usr/bin/env bash
# Run tivtc regression tests against the built plugin.
# Requires: uv (https://docs.astral.sh/uv/)
set -euo pipefail
cd "$(dirname "$0")"

# Build the plugin first if needed
if [ ! -f ../build-cpp/libtivtc.dylib ] && [ ! -f ../build-cpp/libtivtc.so ]; then
    echo "Building tivtc..." >&2
    (cd .. && meson setup build-cpp && ninja -C build-cpp)
fi

exec uv run pytest issues/ -v "$@"
