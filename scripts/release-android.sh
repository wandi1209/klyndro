#!/usr/bin/env bash
# Builds a release APK. Signs it when KLYNDRO_KEYSTORE is set; otherwise the APK is unsigned
# and cannot be installed until it is signed. No keystore or password is stored in the repo.
#
#   KLYNDRO_KEYSTORE=/path/to/release.jks \
#   KLYNDRO_KEYSTORE_PASSWORD=... KLYNDRO_KEY_ALIAS=klyndro KLYNDRO_KEY_PASSWORD=... \
#   ./scripts/release-android.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/apps/android"

./gradlew :app:testDebugUnitTest :app:assembleRelease --console=plain

mkdir -p "$repo_root/dist"
if [[ -n "${KLYNDRO_KEYSTORE:-}" ]]; then
    src="app/build/outputs/apk/release/app-release.apk"
    dest="$repo_root/dist/Klyndro-android-release.apk"
else
    src="app/build/outputs/apk/release/app-release-unsigned.apk"
    dest="$repo_root/dist/Klyndro-android-release-UNSIGNED.apk"
    echo "WARNING: KLYNDRO_KEYSTORE not set; APK is unsigned and not installable." >&2
fi
cp "$src" "$dest"
shasum -a 256 "$dest"
echo "Android release: $dest"
