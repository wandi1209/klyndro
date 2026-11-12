#!/usr/bin/env bash
# Static checks that back the security review. Exits non-zero on the first violated rule.
# These are grep-level guards, not a substitute for reading the code.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
fail=0

check() { # description, pattern, paths...
    local desc="$1" pattern="$2"; shift 2
    local hits
    hits="$(grep -rEn --exclude-dir=.build --exclude-dir=build --exclude-dir=.gradle "$pattern" "$@" 2>/dev/null || true)"
    if [[ -n "$hits" ]]; then
        echo "FAIL: $desc"; echo "$hits"; fail=1
    else
        echo "ok:   $desc"
    fi
}

swift_src=(apps/macos/Klyndro apps/macos/KlyndroKit/Sources)
kt_src=(apps/android/app/src/main)

check "no secrets or keystores tracked" 'BEGIN (RSA |EC )?PRIVATE KEY' protocol apps docs scripts
if git ls-files | grep -Eq '\.(jks|keystore|p12|pem)$'; then
    echo "FAIL: key material file tracked in git"; fail=1
else
    echo "ok:   no key material files tracked"
fi
check "no analytics/telemetry SDKs" 'firebase|crashlytics|sentry|mixpanel|amplitude|appcenter' \
    apps/android/app/build.gradle.kts apps/android/gradle/libs.versions.toml apps/macos/KlyndroKit/Package.swift
# Scoped to .kt/.swift so XML namespace URIs (http://schemas.android.com/...) are not matched.
check "no cleartext http:// endpoints" '"http://|[^s]http://[a-z0-9]' "${swift_src[@]}" "${kt_src[@]}" --include=*.kt --include=*.swift
# The one allowed use of javax.crypto.Cipher is KeystoreSecretBox: platform AES-GCM with a
# non-exportable Android Keystore key (ADR 0008). Anything else is a violation.
check "no custom crypto primitives" 'CommonCrypto|CCCrypt|SecretKeySpec|Cipher\.getInstance' "${swift_src[@]}" "${kt_src[@]}" --exclude=EncryptedTrustStore.kt
check "no credentials in UserDefaults / SharedPreferences" 'UserDefaults\.standard\.(set|string|data).*(key|secret|token|private)|getSharedPreferences.*(private|secret)' "${swift_src[@]}" "${kt_src[@]}"
check "no clipboard/notification content logged (Swift)" '(NSLog|print|logger\.[a-z]+)\(.*(clipboard|notification)\.?(text|body|content|title)' "${swift_src[@]}"
# KlyndroNotificationListener logs the app name, a notification key and the connection phase
# only; never title or text. Any other Log call that mentions content is a violation.
check "no clipboard/notification content logged (Kotlin)" 'Log\.[dviwe]\(.*(clipboard|\.text|\.title|sbn)' "${kt_src[@]}"
check "no force-unwrap in app sources (Swift)" '[A-Za-z\)\]]!\.[a-z]|[a-z]\)!$' apps/macos/Klyndro

exit "$fail"
