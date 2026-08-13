#!/usr/bin/env bash
# Publishes the built Mac app as a GitHub release.
# Asset is always named Qopy.zip so /releases/latest/download/Qopy.zip never needs updating.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"

command -v gh >/dev/null || { echo "needs the GitHub CLI: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "not logged in; run gh auth login"; exit 1; }

cd "$ROOT"
git diff --quiet && git diff --cached --quiet \
    || { echo "uncommitted changes; commit them first"; exit 1; }
git fetch -q origin
git merge-base --is-ancestor HEAD origin/main \
    || { echo "HEAD is not on origin/main yet; push first"; exit 1; }

"$ROOT/scripts/build-release.sh"

APP="$ROOT/dist/Qopy.app"
ZIP="$ROOT/dist/Qopy.zip"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
TAG="v$VERSION"

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "$TAG is already released; bump MARKETING_VERSION in the Xcode project first"
    exit 1
fi

echo "==> publishing $TAG"
NOTES=$(cat <<'EOF'
Apple Silicon, macOS 26 or later.

### Whats new
- Phones can now send photos and files, not just text. Tap Choose photos or files on the phone page
- Files are saved to ~/Downloads, and a single image is copied to the clipboard too
- The receive panel shows what arrived, with Show in Finder
- Up to 100 MB per transfer, with a progress readout on the phone

### Install

1. Download Qopy.zip below, unzip it, and drag Qopy.app to Applications.
2. Open it. macOS may refuse the first time: the app is signed locally, but not notarized by Apple.
3. Go to System Settings > Privacy & Security, scroll to Security, and click Open Anyway.
4. Grant Accessibility when asked. Camera is only needed for the optional QR scan fallback.

Menubar QR icon.
Control-Option-Command-C sends selection. Control-Option-Shift-Command-C sends clipboard. Control-Option-Command-V opens receive.
EOF
)
gh release create "$TAG" "$ZIP" --title "Qopy $VERSION" --notes "$NOTES"

echo
echo "released $TAG"
echo "always-latest: https://github.com/dsalehipour/qopy/releases/latest/download/Qopy.zip"
