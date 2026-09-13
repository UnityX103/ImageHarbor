#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$PWD/work/tests"
ARCH=$(uname -m)
VENDOR="${VENDOR_ROOT:-$PWD/work/vendor}"
mkdir -p "$BUILD"
python3 scripts/fetch_dependencies.py "$ARCH"
swiftc Core.swift Tests/ExportTests.swift -o "$BUILD/export-tests"
"$BUILD/export-tests"
swiftc SystemProxy.swift Tests/SystemProxyTests.swift -o "$BUILD/system-proxy-tests"
"$BUILD/system-proxy-tests"
python3 Tests/CaptureIntegration.py "$VENDOR/$ARCH/mitmproxy.app/Contents/MacOS/mitmdump"
if [ "${CI:-}" = "true" ]; then
  swiftc SystemProxy.swift Tests/SystemConfigurationIntegration.swift -o "$BUILD/sc-integration"
  sudo -n "$BUILD/sc-integration"
fi
python3 -m unittest discover -s Tests -p 'test_*.py'
