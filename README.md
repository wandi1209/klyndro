# Klyndro

**Your devices, seamlessly connected.**

Klyndro is an open-source alternative to proprietary Android ↔ macOS ecosystem
integration. It pairs your phone with your Mac over the local network — no account, no
cloud, no relay — and aims to provide shared clipboard, screen mirroring, remote control,
notifications, and file transfer.

> **Project status: M0-M5 verified on real hardware; M6 (release engineering) builds are in place.**
> A MacBook Air M3 and a Redmi Note 13 5G (HyperOS 3, Android 15) pair with a six-digit code,
> reconnect over Wi-Fi with pinned keys, sync text both ways, mirror the screen with scrcpy, and
> forward Android notifications and files to the Mac. Android only allows clipboard access to the
> app on screen, so clipboard sync runs while Klyndro is open; that is a platform rule, not a bug.
> **Not tested:** Mac -> Android file transfer, fullscreen mirroring, background/screen-off
> clipboard, HyperOS autostart/battery settings, the minified Android release APK on a device,
> Hardened Runtime at runtime, and notarisation. See
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
| M6 | Release engineering, packaging, security review | **Builds and docs done**; signed/notarised distribution and on-device test of release builds NOT TESTED |

## Features

In priority order.

| Feature | Plan | Status |
| --- | --- | --- |
| Secure device identity and pairing | Self-signed P-256 identity, mutual TLS 1.3, pinned SPKI, six-digit SAS | **Verified on device** (macOS responder + Android initiator + UI) — real pairing and pinned reconnect over Wi-Fi |
| Universal clipboard | Bidirectional text sync with loop suppression | **Verified on device** in both directions with loop suppression; foreground only (Android rule) |
| Screen mirroring and control | Managed `scrcpy` process | **Verified on device** (USB + Wi-Fi); fullscreen NOT verified |
| Automatic reconnection | Bounded exponential backoff, network-change aware | **Verified on device** (mDNS live match, backoff retry, sleep/wake recovery) |
| Notification forwarding | `NotificationListenerService` → macOS notifications | **Verified on device** (5-min dedup, native banner delivery) |
| File transfer | Direct local-network transfer with integrity checks | **Verified on device** (Android → Mac chunked transfer + SHA-256) |
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

- No UI tests on either platform. The macOS app was launched and its Bonjour advertisement
  verified with `dns-sd`; its controls were not exercised. The Android APK has been installed and
  its Devices screen observed rendering, but its controls have not been exercised in a live
  session.
- Manual IP entry (F01) is specified but not in the UI.
- A pairing made over the USB button stores `127.0.0.1` as the Mac's address, which goes stale
  when the tunnel drops; the reconnect fallback hides this rather than fixing the stored value.
- Releases are ad-hoc signed on macOS and unsigned on Android unless you supply your own keys
  ([release guide](docs/development/release.md)). No Developer ID identity was available, so
  notarisation has not been run.
- Mirroring is not restricted to Klyndro-paired phones (security review S11).

## Roadmap

All planned milestones have an implementation. Remaining work is verification and distribution:
run the signed release builds on a device pair, test Mac -> Android file transfer, and obtain a
Developer ID identity for notarised macOS builds. See the
[architecture overview](docs/architecture/overview.md) and the
[protocol specification](protocol/specification/klyndro-protocol-v1.md).

## License

MIT. Klyndro invokes the user's own `scrcpy` installation (Apache 2.0) and does not bundle
or modify it. See [LICENSE](LICENSE).
