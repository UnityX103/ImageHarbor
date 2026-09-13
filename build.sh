#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SOURCE="$PWD"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Use arm64 or x86_64" >&2; exit 2 ;; esac
BUILD="${BUILD_DIR:-$SOURCE/work/build/$ARCH}"
OUT="${OUTPUT_DIR:-$SOURCE/dist/$ARCH}"
VENDOR="${VENDOR_ROOT:-$SOURCE/work/vendor}"
export VENDOR_ROOT="$VENDOR"
mkdir -p "$BUILD" "$OUT"
python3 scripts/fetch_dependencies.py "$ARCH"
APP="$OUT/Image Harbor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
SPARKLE="$VENDOR/sparkle"
MINIMUM=$(python3 -c 'import json; print(json.load(open("release/config.json"))["minimum_macos"])')
swiftc -O -target "$ARCH-apple-macosx$MINIMUM" \
  -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  Core.swift App.swift CertificateGuide.swift SystemProxy.swift UpdateCoordinator.swift \
  -o "$APP/Contents/MacOS/ImageHarbor"
swiftc -O -target "$ARCH-apple-macosx$MINIMUM" SystemProxy.swift ProxyAgent.swift -o "$APP/Contents/MacOS/ImageHarborProxy"
codesign --force --sign - "$APP/Contents/MacOS/ImageHarborProxy"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
ditto "$VENDOR/$ARCH/mitmproxy.app" "$APP/Contents/Resources/mitmproxy.app"
cp capture.py THIRD-PARTY-NOTICES.md LICENSE "$APP/Contents/Resources/"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
swift Icon.swift "$BUILD/icon-png"
mkdir -p "$BUILD/AppIcon.iconset"
for size in 16 32 128 256 512; do
  cp "$BUILD/icon-png/$size.png" "$BUILD/AppIcon.iconset/icon_${size}x${size}.png"
  cp "$BUILD/icon-png/$((size*2)).png" "$BUILD/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
python3 scripts/write_plist.py "$ARCH" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/verify_bundle.py "$APP" "$ARCH"
echo "Built: $APP"
