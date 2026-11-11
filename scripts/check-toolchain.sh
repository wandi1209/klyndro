#!/usr/bin/env bash
# Reports the state of every tool Klyndro needs. Read-only: installs nothing.
set -uo pipefail

status=0

section() {
    printf '\n== %s\n' "$1"
}

have() {
    command -v "$1" >/dev/null 2>&1
}

report() {
    local name="$1" detail="$2" required="$3"
    printf '  %-14s %-8s %s\n' "$name" "$([[ "$required" == yes ]] && echo required || echo optional)" "$detail"
}

section "macOS"
printf '  %-14s %s\n' "macOS" "$(sw_vers -productVersion 2>/dev/null || echo 'not macOS')"
printf '  %-14s %s\n' "Architecture" "$(uname -m)"

section "macOS build chain"
if have xcodebuild; then
    report "xcodebuild" "$(xcodebuild -version 2>/dev/null | head -1)" yes
else
    report "xcodebuild" "MISSING — install Xcode" yes
    status=1
fi

if have swift; then
    report "swift" "$(swift --version 2>/dev/null | head -1)" yes
else
    report "swift" "MISSING" yes
    status=1
fi

section "Android build chain"
if have java; then
    java_version="$(java -version 2>&1 | head -1)"
    report "java" "$java_version" yes
else
    report "java" "MISSING — JDK 17+ required" yes
    status=1
fi

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
if [[ -d "$sdk_root" ]]; then
    report "android sdk" "$sdk_root" yes
    platforms="$(ls -1 "$sdk_root/platforms" 2>/dev/null | tr '\n' ' ')"
    report "platforms" "${platforms:-none installed}" yes
    build_tools="$(ls -1 "$sdk_root/build-tools" 2>/dev/null | tail -1)"
    report "build-tools" "${build_tools:-none installed}" yes
else
    report "android sdk" "MISSING — set ANDROID_HOME" yes
    status=1
fi

section "Device tooling"
if have adb; then
    report "adb" "$(adb version 2>/dev/null | head -1)" optional
elif [[ -x "$sdk_root/platform-tools/adb" ]]; then
    report "adb" "$sdk_root/platform-tools/adb" optional
else
    report "adb" "not found — screen mirroring and device testing unavailable" optional
fi

if have scrcpy; then
    report "scrcpy" "$(scrcpy --version 2>/dev/null | head -1)" optional
else
    report "scrcpy" "not found — screen mirroring unavailable (brew install scrcpy)" optional
fi

printf '\n'
if [[ "$status" -eq 0 ]]; then
    echo "Required toolchain is present."
else
    echo "Required toolchain is incomplete; see the list above." >&2
fi
exit "$status"
