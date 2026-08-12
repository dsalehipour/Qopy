#!/usr/bin/env bash
# Builds a Release Qopy.app and packages dist/Qopy.zip for GitHub Releases.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"
IDENTITY="qopy-dev"

cd "$ROOT/Mac"
xcodebuild -scheme Qopy -configuration Release -derivedDataPath build-release \
    -destination 'platform=macOS' build

SRC="$ROOT/Mac/build-release/Build/Products/Release/Qopy.app"
DIST="$ROOT/dist"
APP="$DIST/Qopy.app"
ZIP="$DIST/Qopy.zip"

rm -rf "$DIST"
mkdir -p "$DIST"
ditto "$SRC" "$APP"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --options runtime --sign "$IDENTITY" --identifier com.qopy.app "$APP"
else
    echo "==> no '$IDENTITY' identity; run scripts/create-signing-identity.sh" >&2
    codesign --force --deep --sign - --identifier com.qopy.app "$APP"
fi
codesign --verify --strict "$APP"

rm -f "$ZIP"
# ditto keeps the signature intact across the zip round-trip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

UNPACKED=$(mktemp -d)
trap 'rm -rf "$UNPACKED"' EXIT
ditto -x -k "$ZIP" "$UNPACKED"
codesign --verify --strict "$UNPACKED/Qopy.app"

SIZE=$(du -h "$ZIP" | awk '{print $1}')
echo "Built $APP"
echo "Packaged $ZIP ($SIZE)"
