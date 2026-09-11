#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/qopy-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Mac/Qopy/ClipboardPayload.swift" \
  "$ROOT/Mac/Qopy/TextPayload.swift" \
  "$ROOT/Mac/Qopy/QRCodeGenerator.swift" \
  "$ROOT/Mac/Qopy/LocalWebServer.swift" \
  "$ROOT/Mac/Qopy/AppModel.swift" \
  "$ROOT/Mac/Qopy/SelectionCapture.swift" \
  "$ROOT/Mac/Qopy/GlassChrome.swift" \
  "$ROOT/Mac/Qopy/SendQRView.swift" \
  "$ROOT/Mac/Qopy/ReceiveView.swift" \
  "$ROOT/tests/TransferTests.swift" -o "$TEST_BUILD/transfers"
"$TEST_BUILD/transfers" \
  "$ROOT/assets/app-icon.png" \
  "$ROOT/assets/download-button.png" \
  "$ROOT/assets/phone-page.png" \
  "$@"
