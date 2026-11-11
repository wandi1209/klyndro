# Klyndro

**Your devices, seamlessly connected.**

Klyndro is an open-source alternative to proprietary Android ↔ macOS ecosystem
integration. It pairs your phone with your Mac over the local network — no account, no
cloud, no relay — and aims to provide shared clipboard, screen mirroring, remote control,
notifications, and file transfer.

> **Project status: M2 (clipboard) implemented and host-verified; on-hardware verification is
> BLOCKED.** The clipboard sync engines, the macOS pasteboard integration, the Android foreground
> connection service, the pairing/connect flow and UI, and the foreground + explicit clipboard
> paths are all built and covered by the unit suites (148 Swift tests including a two-peer
> clipboard integration test; 102 Android JVM tests). All host build/test targets are green:
> `swift test`, `:app:testDebugUnitTest`, the macOS app build, and `:app:assembleDebug` /
> `:app:assembleDebugAndroidTest`. **A cross-device session has not succeeded yet**: the first
> on-device pairing attempt failed (`internal`, root cause undiagnosed) and the test device is now
> detached, so live Mac↔phone pairing and clipboard verification are **BLOCKED**. See
> [verification status](docs/testing/verification-status.md).

## Status

| Milestone | Scope | Status |
| --- | --- | --- |
| M0 | Research, architecture, protocol spec, repository + app skeletons, build/test commands | **Complete** |
| M1 | Discovery, secure pairing, authentication, connection lifecycle | **Complete** — verified on Mac + Redmi Note 13 5G |
| M2 | Bidirectional clipboard | **Implemented** — host/unit verified; on-device verification BLOCKED (device detached) |
| M3 | Screen mirroring via scrcpy | Not started |
| M4 | Login item, menu bar integration, reconnect, Android service lifecycle | Not started |
| M5 | Notifications, file transfer | Not started |
| M6 | Release engineering, packaging, security review | Not started |

## Features

Planned, in priority order. None of the application features are implemented at M0.

| Feature | Plan | Status |
| --- | --- | --- |
| Secure device identity and pairing | Self-signed P-256 identity, mutual TLS 1.3, pinned SPKI, six-digit SAS | **Implemented** (macOS responder + Android initiator + UI) — logic/TLS verified both stacks; first real-network attempt **FAIL**, diagnosis **BLOCKED** |
| Universal clipboard | Bidirectional text sync with loop suppression | **Implemented** — engines + macOS pasteboard + Android foreground/explicit paths; unit-verified; on-device **BLOCKED** |
| Screen mirroring and control | Managed `scrcpy` process | Designed (M3) |
| Automatic reconnection | Bounded exponential backoff, network-change aware | Designed (M4) |
| Notification forwarding | `NotificationListenerService` → macOS notifications | Designed (M5) |
| File transfer | Direct local-network transfer with integrity checks | Designed (M5) |
| Menu bar integration | `MenuBarExtra`, launch at login | Shell exists (M4) |

## Requirements

Verified on the development machine listed in
[toolchain inventory](docs/development/toolchain-inventory.md).

**macOS app**

- macOS 14 or later (Apple Silicon recommended; universal builds planned)
- Xcode 26 or later with the macOS SDK
- Swift 6

**Android app**

- Android 10 (API 29) or later; developed against API 37, targeting API 36. Verified on
  Android 15 / HyperOS 3
- JDK 17
- Android SDK with platform `android-37.0` and build-tools 36+
- Gradle is provided via the Wrapper (9.7.1); no global install needed

**Optional, for mirroring**

- `adb` (Android SDK Platform Tools)
- `scrcpy` 3.x or later (tested against 5.0.1)

## Development setup

```bash
git clone <your-fork> klyndro
cd klyndro

# Read-only environment report: versions, SDKs, adb, scrcpy
./scripts/check-toolchain.sh

# macOS: protocol tests + app build
./scripts/build-macos.sh

# Android: debug APK + JVM unit tests
./scripts/build-android.sh

# Both unit suites
./scripts/test-all.sh

# On-device tests (attached, unlocked phone required)
./scripts/test-device.sh
```

Full instructions, including the Android SDK platform that must be installed, are in
[development setup](docs/development/setup.md) and
[build and test](docs/development/build-and-test.md).

## Repository layout

```text
klyndro/
├── apps/
│   ├── macos/
│   │   ├── Klyndro.xcodeproj      # app project (file-system synchronized groups)
│   │   ├── Klyndro/               # SwiftUI app: menu bar, windows, settings
│   │   └── KlyndroKit/            # SwiftPM package: protocol, state machine, diagnostics
│   └── android/
│       ├── app/                   # Compose app + JVM test suite
│       └── gradle/                # Wrapper and version catalog
├── protocol/
│   ├── specification/             # normative wire protocol (v1 draft)
│   └── fixtures/                  # shared conformance fixtures (both test suites)
├── scripts/                       # toolchain check and build/test entry points
├── docs/
│   ├── architecture/
│   ├── decisions/                 # architecture decision records
│   ├── development/
│   └── testing/
├── AGENTS.md
└── LICENSE
```

## Limitations (important)

These are platform facts, not missing polish. Each is documented with sources in
[platform limitations](docs/architecture/platform-limitations.md).

- **Android blocks background clipboard access.** Since Android 10, an app that is neither
  focused nor the active keyboard cannot read *or write* the clipboard. A foreground
  service does not change this. Fully automatic clipboard sync therefore cannot be
  promised; Klyndro plans explicit fallbacks and will publish per-device test results.
- **HyperOS adds its own background rules.** Autostart and battery settings must be
  adjusted by the user, and HyperOS may still stop background work. Not yet tested: no
  Android device is connected to the development machine.
- **scrcpy has no embeddable library.** Klyndro launches it as a child process. Sandboxing
  and distribution choices follow from that (see ADR 0006).
- **Android now holds a connection, but pairing is unproven.** A foreground service
  (`KlyndroService`) opens the socket, and the Devices screen drives pairing and connect. The
  first end-to-end pairing attempt returned `internal` on the phone and has not been diagnosed;
  `KlyndroPairing` logging is in place for the next attached session.
- **Nothing has been verified device-to-device.** Each side is verified on its own (unit +
  on-device loopback for M1); the first successful Mac↔phone clipboard session still has to
  happen, and is BLOCKED while the device is detached.
- **HyperOS install quirk.** USB installs fail while the screen is locked
  (`INSTALL_FAILED_USER_RESTRICTED`), and Gradle can report `BUILD SUCCESSFUL` even when the test
  APK failed to install. See [compatibility matrix](docs/testing/compatibility-matrix.md).

## Known gaps

- No launcher icon on Android (system default is used). Icon design is M6 work.
- No UI tests on either platform. The macOS app was launched and its Bonjour advertisement
  verified with `dns-sd`; its controls were not exercised. The Android APK has been installed and
  its Devices screen observed rendering, but its controls have not been exercised in a live
  session.
- Manual IP entry (F01) is specified but not in the UI.
- The M2 clipboard paths are implemented but not proven device-to-device: the first pairing
  attempt failed (`internal`) and diagnosis is BLOCKED while the device is detached.
- Release builds, signing, notarisation, and packaging are deliberately out of scope until M6.

## Roadmap

M2 (clipboard) is implemented and host-verified; finishing it needs an attached device to
diagnose the pairing `internal` failure and prove the live clipboard paths. M3 (mirroring)
follows. See [architecture overview](docs/architecture/overview.md)
for the component design and [the protocol specification](protocol/specification/klyndro-protocol-v1.md)
for the contract between the two apps.

## License

MIT. Klyndro invokes the user's own `scrcpy` installation (Apache 2.0) and does not bundle
or modify it. See [LICENSE](LICENSE).
