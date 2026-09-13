#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) exit 2 ;; esac
OUT="${OUTPUT_DIR:-$PWD/dist/$ARCH}"
BUILD="${BUILD_DIR:-$PWD/work/build/$ARCH}"
VERSION=$(python3 -c 'import json; print(json.load(open("release/config.json"))["version"])')
APP="$OUT/Image Harbor.app"
python3 scripts/verify_bundle.py "$APP" "$ARCH"
STAGE=$(mktemp -d "$BUILD/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Image Harbor.app"
ln -s /Applications "$STAGE/Applications"
cp README.md "$STAGE/README.md"
hdiutil create -volname 'Image Harbor' -srcfolder "$STAGE" -ov -format UDZO "$OUT/ImageHarbor-$VERSION-$ARCH.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/ImageHarbor-$VERSION-$ARCH.zip"
