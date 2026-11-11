# Compatibility matrix

Last updated: 2026-11-11 (M2). Only rows marked `PASS` have been executed. On-device M2 runs
(pairing, clipboard) are **BLOCKED** — the test device is detached.

## macOS

| Version | Build | Launch | Discovery (advert) | Clipboard | Mirroring | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 14 (Sonoma) | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | Deployment target, unverified |
| 15 (Sequoia) | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | Unverified |
| 26 | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | Unverified |
| 27 | **PASS** | **PASS** | **PASS** | — | — | Build host (macOS 27.0.1, arm64) |

Notes:

- Deployment target is macOS 14.0 (`MACOSX_DEPLOYMENT_TARGET = 14.0`, SwiftPM
  `.macOS(.v14)`). Only 27.0.1 has been exercised.
- Apple Silicon is the primary target (arm64 build and tests verified). Intel is unbuilt.
- Discovery was verified with `dns-sd -B` / `dns-sd -L`: the service appears as
  `<device name> [<last 6 of device id>]` on `_klyndro._tcp.local.` with port 47823 and the
  expected TXT keys.

## Android

| Version | API | Install | Launch | Keystore identity | TLS session | NSD advert | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Android 10 | 29 | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | `minSdk` |
| Android 11 | 30 | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | Unverified |
| Android 12 | 31 | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | Unverified |
| Android 13 | 32 | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | Unverified |
| Android 14 | 34 | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | Unverified |
| **Android 15** | **35** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Redmi Note 13 5G |
| Android 16 | 36 | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | `targetSdk` |
| Android 17 | 37 | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | `compileSdk` only |

Build verification (host, no device required): `:app:assembleDebug`, `:app:testDebugUnitTest`
(102 tests) and `:app:assembleDebugAndroidTest` all pass. `:app:connectedDebugAndroidTest`
requires an attached, unlocked device and has **not** been re-run since the device was detached;
the last full on-device run was the 7-test M1 suite (**PASS**).

## OEM skin

| Device | Skin | Base | Status |
| --- | --- | --- | --- |
| Redmi Note 13 5G (`2312DRAABG`, `iron`) | HyperOS 3.0 (`OS3.0.3.0.VNQIDXM`) | Android 15 (API 35) | Identity, TLS, and NSD verified (see below) |

### HyperOS observations from the first on-device session

| Behaviour | Observation |
| --- | --- |
| `adb install` while the screen is **locked** | Fails with `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`. Unlock before installing; `scripts/test-device.sh` checks the keystore state first. |
| Gradle exit code on a failed instrumentation install | `connectedDebugAndroidTest` printed `AndroidTestRunner failed … INSTALL_FAILED_USER_RESTRICTED` **but still reported `BUILD SUCCESSFUL`**. Never trust the exit code alone; read `app/build/outputs/androidTest-results/connected/debug/`. |
| NSD advertisement via `NsdManager` | Works. The Mac saw the phone as `Klyndro Android Test [2c7b1a]` and resolved it to `Android_UYJ1H0OU.local.:47823` with the full TXT record (`fp`, `id`, `caps`, `name`, `proto=1`). |
| Keystore-backed identity | Works. Reloading the identity returns the same fingerprint. |
| Dark theme | Follows the system; the custom light/dark palettes render correctly. |
| Autostart / battery restrictions | **Not yet exercised** (no background service exists). |
| Clipboard read/write while focused (M2) | **BLOCKED** — `AndroidClipboardInstrumentedTest` (launches `MainActivity` for focus, write→read round trip, `EXTRA_IS_SENSITIVE` detection) is written and compiles, but has not run: the device is detached. |
| macOS ↔ Android pairing over the LAN (M2) | **FAIL** once, then **BLOCKED** — a single end-to-end attempt showed `internal` on the phone; root cause undiagnosed. `KlyndroPairing` logging is in place for the next attached session. |

## External tools

| Tool | Version | Verified |
| --- | --- | --- |
| scrcpy | 5.0.1 | Detected and version-reported (`PASS`); process control untested |
| adb / platform-tools | 1.0.41 / 36.0.2 | `PASS` — device enumerated as `hiam6hf6lfsshuif`, USB transport |
| Gradle | 9.7.1 | `PASS` |
| AGP | 9.5.1 | `PASS` — including `connectedDebugAndroidTest` |
| Kotlin (AGP built-in) | 2.2.10 | `PASS` |
| Xcode / Swift | 27.1 / 6.4 | `PASS` |

## Recording a new result

Add the row with the exact version, the command or observation, and the date, then update
[verification status](verification-status.md). Do not copy a `PASS` from another version
without running it.
