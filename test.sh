#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../work
TEST_WORK="$(cd ../../work && pwd)"
xcrun swiftc Sources/Curve.swift Sources/DPI.swift Sources/GameWindow.swift Tests/main.swift -framework AppKit -framework IOKit -module-cache-path "$TEST_WORK/dpi-test-cache" -o ../../work/curve-tests
../../work/curve-tests
