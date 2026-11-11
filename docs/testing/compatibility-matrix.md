# Compatibility matrix

Last updated: 2026-11-11 (M2). Only rows marked `PASS` have been executed. On-device M2 runs
(pairing, reconnect, clipboard) were executed on the Redmi Note 13 5G; see the HyperOS table below.

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
(102 tests) and `:app:assembleDebugAndroidTest` all pass. On-device, the full instrumented suite
(11 tests across 5 classes) passed via `am instrument` with the app in front. Gradle's
`connectedDebugAndroidTest` was only re-run for the trust-store class (3 tests, **PASS**).

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
| Clipboard access from a **non-focused** caller | **Denied**, as documented. `logcat`: `ClipboardService: Denying clipboard access to id.my.wandidev.klyndro, application is not in focus nor is it a system service`. The instrumented test thread is not the focused window even while `MainActivity` is on screen, so it failed until the calls ran inside `ActivityScenario.onActivity`. |
| Clipboard read/write from the focused Activity (M2) | **PASS** — write then read returns the text; `EXTRA_IS_SENSITIVE` is readable from `ClipDescription.extras` only when set through a fresh `PersistableBundle`. |
| `ActivityScenario.launch` for a second test class in one run | **Unreliable on HyperOS.** A second launch stalled for tens of seconds. Keep clipboard checks in one launch per run. |
| `adb shell cmd clipboard` / `service call clipboard` | Not usable to seed the clipboard: `cmd clipboard` has no implementation and `service call` returns a parcel, not a write. A real copy in another app is needed for end-to-end tests. |
| macOS ↔ Android pairing over the LAN (M2) | **PASS.** The Mac needed to advertise an IPv4 address in its TXT record: NSD resolved only a link-local `fe80::…%wlan0` address, which is unreachable. |
| Phone and Mac on different subnets | The phone was on `192.168.21.x` and the Mac on `192.168.23.x`; TCP and ICMP still worked, so mDNS plus a routed LAN is sufficient for this setup. |
| USB debugging path | `adb reverse tcp:47823 tcp:47823` makes `127.0.0.1:47823` reach the Mac. It disappears when the adb server restarts, which is why a stored `127.0.0.1` address goes stale. |

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
