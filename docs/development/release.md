# Releasing Klyndro

Klyndro is distributed directly, not through an app store (ADR 0006, ADR 0009). Nothing in this
repository holds a signing key or password; both are supplied at build time.

## One-shot

```bash
./scripts/release-all.sh     # audit + Android release + macOS release -> dist/
```

`dist/` is gitignored. Each script prints SHA-256 checksums for the artefacts it writes.

## Android

```bash
KLYNDRO_KEYSTORE=/secure/path/klyndro-release.jks \
KLYNDRO_KEYSTORE_PASSWORD=... KLYNDRO_KEY_ALIAS=klyndro KLYNDRO_KEY_PASSWORD=... \
./scripts/release-android.sh
```

- Release builds enable R8 shrinking and resource shrinking. Wire messages are built through
  Gson `JsonObject` trees with explicit property names, so renaming cannot change the JSON on the
  wire. `proguard-rules.pro` keeps only the manifest-registered components and the BouncyCastle
  providers.
- Without `KLYNDRO_KEYSTORE` the output is `Klyndro-android-release-UNSIGNED.apk`, which Android
  will not install. This is deliberate: a release must never be signed by accident with a debug key.
- Create the keystore once and back it up offline. **Losing it means users cannot upgrade in
  place**, because Android requires the same signing key:
  `keytool -genkeypair -keystore klyndro-release.jks -alias klyndro -keyalg EC -groupname secp256r1 -validity 10000`
- Installing a release build over a debug build fails with a signature mismatch. Uninstalling
  the debug build first deletes the phone's identity and trust store, so the phone must be
  re-paired.
- Output is an APK. An AAB is only needed for Google Play, which is out of scope.

## macOS

```bash
./scripts/release-macos.sh                                        # ad-hoc signed
KLYNDRO_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
    ./scripts/release-macos.sh                                    # Developer ID + Hardened Runtime
```

Produces `Klyndro-macOS-<version>.zip` and `.dmg`.

| Signing | Who can run it | Notes |
| --- | --- | --- |
| Ad-hoc (default) | This Mac. Other Macs: Gatekeeper blocks it until the user approves it in System Settings > Privacy & Security | Fine for development and for testers who accept that |
| Developer ID + notarisation | Any Mac | Requires a paid Apple Developer Program membership |

### Notarisation (manual, not run by the script)

```bash
xcrun notarytool submit dist/Klyndro-macOS-0.1.0.zip --keychain-profile klyndro-notary --wait
xcrun stapler staple dist/.derived/Build/Products/Release/Klyndro.app
```

Store credentials once with `xcrun notarytool store-credentials klyndro-notary`. Re-create the
DMG after stapling. Notarisation was **not executed**: this machine has no Developer ID identity
(`security find-identity -v -p codesigning` returns none).

### Keychain consequence of changing signature

The identity and trust store live in the login Keychain (ADR 0008). Keychain access is tied to the
app's code signature, so moving from ad-hoc to Developer ID makes macOS ask again, and items
created by the ad-hoc build may not be readable. Plan on re-pairing when the signing identity
first changes.

## Versioning

`MARKETING_VERSION` (Xcode project) and `versionName` (`apps/android/app/build.gradle.kts`) must
match; bump `CURRENT_PROJECT_VERSION` / `versionCode` on every release. The protocol version is
independent and changes only through `protocol/specification/`.

## Pre-release checklist

1. `./scripts/audit-repo.sh` passes.
2. `./scripts/test-all.sh` passes.
3. Walk through [the security review](../security/review-checklist.md).
4. Update [verification status](../testing/verification-status.md) with what you ran on the exact
   artefacts you are shipping.
5. Install the signed artefacts on a clean device pair and pair, sync, and reconnect once.
