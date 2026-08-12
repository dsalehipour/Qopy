#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"
cd "$ROOT/Mac"

xcodebuild -scheme Qopy -configuration Debug -derivedDataPath build -destination 'platform=macOS' build

APP="$ROOT/Mac/build/Build/Products/Debug/Qopy.app"
IDENTITY="qopy-dev"

# Re-sign with a fixed local identity so TCC grants (Accessibility, Camera) survive rebuilds.
# Ad-hoc signatures change every build and silently revoke those grants.
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" --identifier com.qopy.app "$APP"
else
    echo "==> no '$IDENTITY' identity found — signing ad-hoc."
    echo "    Permissions will need re-approving after every build."
    echo "    Run once: scripts/create-signing-identity.sh"
    codesign --force --deep --sign - --identifier com.qopy.app "$APP"
fi
codesign --verify --verbose=1 "$APP"

echo "Built: $APP"
