# Klyndro

**Your devices, seamlessly connected.**

Klyndro is an open-source alternative to proprietary Android ↔ macOS ecosystem
integration. It pairs your phone with your Mac over the local network — no account, no
cloud, no relay — and aims to provide shared clipboard, screen mirroring, remote control,
notifications, and file transfer.

> **Project status: M0–M6 verified on real hardware (`v0.1.0` published).**
> A MacBook Air M3 and a Redmi Note 13 5G (HyperOS 3, Android 15) pair with a six-digit code,
> reconnect over Wi-Fi with pinned keys, sync text both ways, mirror the screen with scrcpy
> (scoped to the paired phone via §5.4a challenge/proof), and forward Android notifications and
> files both ways between phone and Mac. Android only allows clipboard access to the app on screen,
> so clipboard sync runs while Klyndro is open; that is a platform rule, not a bug.
> **Not tested / blocked:** fullscreen mirroring, background/screen-off clipboard, HyperOS
> autostart/battery settings, two-phone mismatch for mirror scoping, and Apple Developer ID
> notarisation (`BLOCKED` — no Developer ID identity). See
> [verification status](docs/testing/verification-status.md) and the
> [security review](docs/security/review-checklist.md).

## Status

| Milestone | Scope | Status |
| --- | --- | --- |
| M0 | Research, architecture, protocol spec, repository + app skeletons, build/test commands | **Complete** |
| M1 | Discovery, secure pairing, authentication, connection lifecycle | **Complete** — verified on Mac + Redmi Note 13 5G |
| M2 | Bidirectional clipboard | **Verified on device** while the Android app is on screen; background behaviour NOT TESTED |
| M3 | Screen mirroring via scrcpy | **Verified on device** (USB + Wi-Fi, mouse/keyboard control, rotate, resize, screen-off, clean stop); fullscreen NOT verified |
| M4 | Login item, menu bar integration, reconnect, Android service lifecycle | **Verified on device** (Android auto-connect on resume, mDNS trigger, backoff retry, macOS NWPathMonitor & sleep/wake) |
| M5 | Notifications, file transfer | **Verified on device** (Android -> Mac notification banner + chunked file transfer with SHA-256 verification) |
| M6 | Release engineering, packaging, security review | **Verified on device (`v0.1.0`)** — signed Android APK & ad-hoc macOS DMG verified on hardware; Developer ID notarisation **BLOCKED** |

## Features

In priority order.

| Feature | Plan | Status |
| --- | --- | --- |
| Secure device identity and pairing | Self-signed P-256 identity, mutual TLS 1.3, pinned SPKI, six-digit SAS | **Verified on device** (macOS responder + Android initiator + UI) — real pairing and pinned reconnect over Wi-Fi |
| Universal clipboard | Bidirectional text sync with loop suppression | **Verified on device** in both directions with loop suppression; foreground only (Android rule) |
| Screen mirroring and control | Managed `scrcpy` process | **Verified on device** (USB + Wi-Fi); fullscreen NOT verified |
| Automatic reconnection | Bounded exponential backoff, network-change aware | **Verified on device** (mDNS live match, backoff retry, sleep/wake recovery) |
| Notification forwarding | `NotificationListenerService` → macOS notifications | **Verified on device** (5-min dedup, native banner delivery) |
| File transfer | Direct local-network transfer with integrity checks | **Verified on device** in both directions (chunked, SHA-256) |
| Menu bar integration | `MenuBarExtra`, launch at login | **Verified on device** (`SMAppService.mainApp` + live status/controls) |

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
  adjusted by the user, and HyperOS may still stop background work. Autostart and battery
  behaviour have not been tested yet (M4).
- **scrcpy has no embeddable library.** Klyndro launches it as a child process. Sandboxing
  and distribution choices follow from that (see ADR 0006).
- **Clipboard sync only runs while Klyndro is on screen.** The foreground service holds the
  socket, but Android lets only the focused app touch the clipboard. A copy made while Klyndro is
  in the background is picked up the next time you open it.
- **Automatic reconnect works via mDNS.** When the app opens or the socket drops, the phone
  retries with bounded exponential backoff and picks up the Mac's IP via live mDNS discovery.
- **Your network must route between the two devices and allow mDNS.** Verified across two subnets
  (`192.168.21.x` and `192.168.23.x`); client-isolation Wi-Fi will block it.
- **HyperOS install quirk.** USB installs fail while the screen is locked
  (`INSTALL_FAILED_USER_RESTRICTED`), and Gradle can report `BUILD SUCCESSFUL` even when the test
  APK failed to install. See [compatibility matrix](docs/testing/compatibility-matrix.md).

## Known gaps

- No automated UI tests (`XCUITest` / Compose UI test) on either platform; live device sessions
  exercised pairing, clipboard, mirroring, notifications, file transfer, and manual IP entry
  (`F01`) manually and via `uiautomator`/deep links.
- macOS releases are ad-hoc signed because no Developer ID identity is available for
  notarisation. GitHub Release Android APKs are signed with the release keystore; local builds
  without `KLYNDRO_KEYSTORE` produce an unsigned APK ([release guide](docs/development/release.md)).

## Roadmap

All planned milestones (M0–M6) are implemented and verified on hardware (`v0.1.0`), and both
open code gaps (`F01` manual IP fallback and USB `lastHost` healing) are verified on device.
Remaining work is obtaining an Apple Developer ID identity for notarised macOS builds. See the
[architecture overview](docs/architecture/overview.md) and the
[protocol specification](protocol/specification/klyndro-protocol-v1.md).

## License

MIT. Klyndro invokes the user's own `scrcpy` installation (Apache 2.0) and does not bundle
or modify it. See [LICENSE](LICENSE).
