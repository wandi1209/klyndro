#!/usr/bin/env bash
# Runs the on-device (instrumentation) test suite. Requires one attached, UNLOCKED device.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/apps/android"

devices="$(adb devices | awk 'NR>1 && $2=="device" {print $1}')"
if [[ -z "$devices" ]]; then
    echo "No Android device in 'device' state. Connect one and accept the debugging prompt." >&2
    adb devices -l >&2
    exit 1
fi

if [[ "$(adb shell dumpsys window 2>/dev/null | grep -c 'mDreamingLockscreen=true' || true)" != "0" ]]; then
    echo "The device screen is locked. HyperOS rejects test APK installs on a locked device." >&2
    echo "Unlock the phone, then re-run this script." >&2
    exit 1
fi

echo "Running instrumentation tests on: $devices"
# HyperOS asks for confirmation on every install; allow a long timeout for that prompt.
./gradlew :app:connectedDebugAndroidTest --console=plain "$@"

echo
echo "Results: apps/android/app/build/outputs/androidTest-results/connected/debug/"
