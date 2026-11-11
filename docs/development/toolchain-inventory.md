# Toolchain inventory

Captured on 2026-11-11 on the development machine. This is a factual snapshot, not a
requirement list; see [setup](setup.md) for what Klyndro actually needs.

## Host

| Item | Value |
| --- | --- |
| OS | macOS 27.0.1 (build 26A434) |
| Architecture | arm64 (Apple Silicon) |
| Homebrew | 7.0.13 |
| Git | 2.49.0 |
| Xcode location | `/Volumes/HOME-LAB/Applications/Xcode.app` |

## Apple toolchain

| Item | Value |
| --- | --- |
| Xcode | 27.1 (build 27A9275) |
| Swift | 6.4 (swiftlang-6.4.0.34.1, clang-2100.3.34.1) |
| Default target | `arm64-apple-macosx27.0.0` |
| macOS SDK | 27.0 |
| Other SDKs | iOS 27.1, tvOS 27.0, watchOS 27.0, visionOS 27.0, DriverKit 27.0 |

## JVM and Android

| Item | Value |
| --- | --- |
| `java` | OpenJDK 17.0.10 (Temurin) |
| `JAVA_HOME` | `~/.sdkman/candidates/java/current` → 17.0.10 |
| Other JDKs installed | 21.0.8-tem, 26-tem |
| `/usr/libexec/java_home` | does not resolve JDKs on this machine; use `JAVA_HOME` |
| `ANDROID_HOME` | `/Volumes/HOME-LAB/Library/Android/sdk` |
| SDK platforms | android-34, android-35, android-36, **android-37.0** |
| Build tools | 35.0.0, 35.0.1, 36.0.0, 36.1.0, 37.0.0 (default for this build: 37.0.0) |
| NDK | 28.2.13676358 (unused) |
| cmdline-tools | `latest` |
| Emulator / system images | present, unused at M0 |
| Gradle | 9.7.1, supplied by the project Wrapper (no global install) |
| Global `gradle` | not installed |

Pinned build versions (see `apps/android/gradle/libs.versions.toml`):

| Component | Version | Why |
| --- | --- | --- |
| AGP | 9.5.1 | Latest stable; requires Gradle ≥ 9.6.0, JDK 17, build-tools 36+ |
| Gradle | 9.7.1 | Wrapper version; satisfies AGP 9.5.1's minimum |
| Kotlin (bundled by AGP) | 2.2.10 | Built-in Kotlin; not applied as a plugin |
| Compose compiler plugin | 2.2.10 | Must match AGP's bundled Kotlin exactly |
| Compose BOM | 2026.09.00 | Current stable Compose/Material3 set |
| Compose UI / Material3 | from BOM (1.12.x / matching M3) | — |
| AndroidX core-ktx | 1.19.1 | Requires `compileSdk 37` |
| AndroidX activity-compose | 1.13.0 | `enableEdgeToEdge`, `setContent` |
| AndroidX lifecycle | 2.11.0 | `viewModel()` + Compose state |
| Gson | 2.15.0 | Tree-API JSON codec (ADR 0007) |
| BouncyCastle bcprov/bcpkix | 1.86 | X.509 encoding for the device identity (ADR 0008) |
| kotlinx-coroutines-core | 1.11.0 | Session, transport and heartbeat concurrency |
| JUnit | 4.13.2 | JVM unit tests |

## macOS packages

| Package | Version | Why |
| --- | --- | --- |
| `apple/swift-certificates` (`X509`) | 1.21.1 | DER-encode the self-signed identity certificate |
| `apple/swift-crypto` | 5.1.1 (transitive) | Signature support used by X509 |
| `apple/swift-asn1` | 1.7.4 (transitive) | ASN.1 underlying X509 |

## Device tooling

| Item | Value |
| --- | --- |
| `adb` | 1.0.41 (platform-tools 36.0.2) at `$ANDROID_HOME/platform-tools/adb` |
| `scrcpy` | 5.0.1 at `/opt/homebrew/bin/scrcpy` |
| Homebrew deps | ffmpeg, ffmpeg@9, sdl2, sdl2-compat, sdl3 |
| Connected Android devices | **none** (`adb devices` is empty) |

## What this means for verification

- Everything that runs on the host (tests, builds, diagnostics) can be verified now.
- Everything that needs a phone (pairing, clipboard, mirroring, HyperOS behaviour) is
  **BLOCKED** until a device is attached. See
  [verification status](../testing/verification-status.md).
- The Android SDK platform `android-37.0` was installed during M0 because current AndroidX
  artifacts require `compileSdk 37`. Nothing else was installed or modified.
