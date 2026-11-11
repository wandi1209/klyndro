#!/usr/bin/env bash
# Builds the macOS app and runs the KlyndroKit test suite.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-Debug}"

echo "== KlyndroKit tests"
swift test --package-path "$repo_root/apps/macos/KlyndroKit"

echo "== Klyndro.app ($configuration)"
xcodebuild \
    -project "$repo_root/apps/macos/Klyndro.xcodeproj" \
    -scheme Klyndro \
    -configuration "$configuration" \
    build

echo "macOS build complete."
