#!/usr/bin/env bash
# Builds a Release Klyndro.app and packages it as a zip and a DMG in dist/.
#
# Signing:
#   default                    ad-hoc ("-"): runs on this Mac; Gatekeeper blocks it elsewhere.
#   KLYNDRO_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#                              signs with Hardened Runtime. Notarise afterwards (see
#                              docs/development/release.md); this script does not upload anything.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
identity="${KLYNDRO_SIGN_IDENTITY:--}"
derived="$repo_root/dist/.derived"
dist="$repo_root/dist"

echo "== KlyndroKit tests"
swift test --package-path "$repo_root/apps/macos/KlyndroKit"

echo "== Release build"
rm -rf "$derived"
mkdir -p "$dist"
xcodebuild \
    -project "$repo_root/apps/macos/Klyndro.xcodeproj" \
    -scheme Klyndro \
    -configuration Release \
    -derivedDataPath "$derived" \
    build

app="$derived/Build/Products/Release/Klyndro.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"

echo "== Signing with: $identity"
if [[ "$identity" == "-" ]]; then
    codesign --force --deep --sign - "$app"
else
    codesign --force --deep --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

zip="$dist/Klyndro-macOS-$version.zip"
dmg="$dist/Klyndro-macOS-$version.dmg"
rm -f "$zip" "$dmg"
ditto -c -k --keepParent "$app" "$zip"

stage="$(mktemp -d)"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Klyndro" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$stage"

shasum -a 256 "$zip" "$dmg"
echo "macOS release: $zip, $dmg"
