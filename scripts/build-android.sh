#!/usr/bin/env bash
# Builds the debug APK and runs the JVM unit tests.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/apps/android"

./gradlew :app:assembleDebug :app:testDebugUnitTest --console=plain

echo "Android build complete: app/build/outputs/apk/debug/app-debug.apk"
