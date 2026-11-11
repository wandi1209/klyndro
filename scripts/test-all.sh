#!/usr/bin/env bash
# Runs both unit test suites. Device tests are manual; see docs/testing/test-plan.md.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== macOS protocol core"
swift test --package-path "$repo_root/apps/macos/KlyndroKit"

echo "== Android protocol core"
cd "$repo_root/apps/android"
./gradlew :app:testDebugUnitTest --console=plain

echo "Both unit suites passed."
