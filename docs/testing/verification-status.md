# Verification status

The single source of truth for what has actually been executed. Last updated: **2026-11-11**
(M2). Clipboard sync is now implemented on both platforms and verified by the host/unit suites;
the first on-device pairing attempt failed and, with the device now detached, all live
Mac↔phone verification is **BLOCKED**.

Device under test: Xiaomi Redmi Note 13 5G (`2312DRAABG`, codename `iron`), HyperOS 3.0
(`OS3.0.3.0.VNQIDXM`), Android 15 (API 35), arm64-v8a, attached over USB as
`hiam6hf6lfsshuif`.

Vocabulary: `PASS` executed and observed working · `FAIL` executed and observed broken ·
`BLOCKED` cannot execute (external constraint) · `NOT TESTED` implemented/designed but
unverified.

## M2 — clipboard synchronization

Implemented on both platforms: the Android foreground service + pairing/connect flow, the
`ConnectionRuntime` seam, `AndroidClipboard` + `ClipboardSyncEngine`, and the foreground clipboard
loop / explicit-send path in `KlyndroViewModel`; on macOS, `ClipboardSync` + `PasteboardMonitor`
wired into the live session, with responder pairing over the `klyndro://pair` deep link.

### Host / unit verification — executed

| # | Claim | Command / evidence | Result |
| --- | --- | --- | --- |
| M2-V1 | macOS protocol + clipboard + crypto suite passes | `swift test --package-path apps/macos/KlyndroKit` | **PASS** — 148 tests in 21 suites, 0 failures |
| M2-V2 | Cross-peer clipboard sync: loop termination, echo suppression, dedup, stale/own-origin rejection, sensitive gate | `ClipboardSyncIntegrationTests` (two in-memory peers + fake pasteboard) | **PASS** |
| M2-V3 | Android JVM suite passes | `cd apps/android && ./gradlew :app:testDebugUnitTest` | **PASS** — 102 tests in 14 classes, 0 failures |
| M2-V4 | Android clipboard engine: dedup, three loop-prevention rules, explicit send, session reset | `ClipboardSyncEngineTest` | **PASS** — 14 tests |
| M2-V5 | macOS app builds | `xcodebuild -project apps/macos/Klyndro.xcodeproj -scheme Klyndro -configuration Debug build` | **PASS** — `** BUILD SUCCEEDED **` |
| M2-V6 | Android debug APK builds | `./gradlew :app:assembleDebug` | **PASS** — `BUILD SUCCESSFUL` |
| M2-V7 | Android instrumented test APK compiles (clipboard + trust-store diagnostics, `ActivityScenario`, real `AndroidKeyStore` AES-GCM) | `./gradlew :app:assembleDebugAndroidTest` | **PASS** — `AndroidClipboardInstrumentedTest.class` + `EncryptedTrustStoreInstrumentedTest.class` produced |

### On-device verification — BLOCKED (device detached)

| # | Claim | Result | Why |
| --- | --- | --- | --- |
| M2-D1 | macOS ↔ Android pairing over a real network | **FAIL** (observed once) → diagnosis **BLOCKED** | One end-to-end attempt showed status `internal` on the phone before the device was detached; root cause not yet determined. Failure logging was added under tag `KlyndroPairing` in `PairingRunner` (peer-key-unavailable, validation, window, persist, and generic-exception paths) to capture it on the next attached session. |
| M2-D2 | Clipboard instrumented test on HyperOS (focused write→read round trip, `EXTRA_IS_SENSITIVE` detection) | **BLOCKED** | `AndroidClipboardInstrumentedTest` is written and compiles; running `connectedDebugAndroidTest` needs an attached, unlocked device. |
| M2-D3 | Android → Mac clipboard (app foreground) | **BLOCKED** | Requires a successful pairing session plus an attached device. |
| M2-D4 | Mac → Android clipboard (app foreground) | **BLOCKED** | Same. |
| M2-D5 | Explicit "Send text to Mac" fallback path | **BLOCKED** | Same. |
| M2-D6 | Sealed trust-store round trip on HyperOS (real `AndroidKeyStore` AES-256-GCM seal/open/reload) | **BLOCKED** | `EncryptedTrustStoreInstrumentedTest` written + compiles; isolates the `trustStore.upsert` path that `persistAndFinish` runs — a prime suspect for M2-D1's `internal`. Needs an attached device. |

### Next attached-device procedure (M2-D1 … M2-D6)

1. Keep the phone unlocked (`adb shell settings put global stay_on_while_plugged_in 2`).
2. **First isolate the trust store**: run `./gradlew :app:connectedDebugAndroidTest
   -Pandroid.testInstrumentationRunnerArguments.class=id.my.wandidev.klyndro.EncryptedTrustStoreInstrumentedTest`
   and read the results XML. If `sealedRoundTripSurvivesReloadWithTheSameKeystoreKey` fails, the
   `internal` in step M2-D1 is the `AndroidKeyStore` AES-GCM path, not the pairing protocol.
3. Run the macOS app from a DEBUG build with `launchctl setenv KLYNDRO_AUTOCONFIRM_PAIRING 1`
   so the responder auto-confirms the six digits.
4. On the phone: Devices tab → Start connection → wait for the Mac to appear → Pair.
5. On the Mac: `open klyndro://pair` to open the 60 s window; on the phone tap Pair, then
   "Codes match".
6. If the phone shows `internal` again, read `adb logcat -d | grep KlyndroPairing` to identify
   which path failed (peer-key-unavailable, validation, window, persist, or generic exception).
7. Once connected: `printf 'MAC-TEXT' | pbcopy` on the Mac must raise the phone's
   "Received from Mac" counter; the phone's "Send text to Mac" field must arrive via `pbpaste`.
8. Run the full `./gradlew :app:connectedDebugAndroidTest` and read
   `app/build/outputs/androidTest-results/connected/debug/*.xml` (never trust the exit code).

## M1 — secure connectivity

### Host verification — executed

| # | Claim | Command / evidence | Result |
| --- | --- | --- | --- |
| V1 | macOS protocol + crypto test suite passes | `swift test --package-path apps/macos/KlyndroKit` | **PASS** — 118 tests in 18 suites, 0 failures |
| V2 | Android JVM test suite passes | `cd apps/android && ./gradlew :app:testDebugUnitTest` | **PASS** — 79 tests in 12 classes, 0 failures |
| V3 | Both apps build | `xcodebuild … -scheme Klyndro build`, `./gradlew :app:assembleDebug` | **PASS** — `BUILD SUCCEEDED`, APK produced |
| V4 | Self-signed identity is created, persisted and reloaded with a stable fingerprint | `DeviceIdentityStore` tests (create → load → delete) | **PASS** |
| V5 | Trust store round-trips through the Keychain | `KeychainTrustStore` test | **PASS** |
| V6 | Mutual TLS 1.3 with pinned keys authenticates both sides (macOS, real sockets) | `TLSIntegrationTests.pinnedMutualTLSAuthenticates` | **PASS** — both fingerprints cross-checked against the certificates |
| V7 | A certificate that is not pinned is refused (macOS) | `TLSIntegrationTests.rejectsUnpinnedPeer` / `rejectsUnpinnedClient` | **PASS** — handshake fails, no session establishes |
| V8 | Mutual TLS 1.3 with pinned keys works on the Android stack (JSSE, real sockets) | `TlsLoopbackTest` | **PASS** — 3 tests: pinned accept, untrusted reject, pairing window |
| V9 | Pairing-code derivation matches an independently computed vector | `protocol/vectors/pairing-sas.json`, asserted by Swift **and** Kotlin | **PASS** — produced with Python `hashlib`, not by either app |
| V10 | Pairing persists both directions and rejects a forged fingerprint / user rejection | `PairingRunnerTests` (in-memory transport) | **PASS** — 4 tests |
| V11 | Session handshake, capability negotiation, ping/pong, protocol violations, handshake timeout | `PeerSessionTests` / `PeerSessionTest` | **PASS** — both platforms |
| V12 | Bonjour advertisement is visible on the real network | launched the app, then `dns-sd -B _klyndro._tcp local.` | **PASS** — `Wandi MacBook [f42dc1]` appeared |
| V13 | The advertised service resolves to the spec port with the full TXT record | `dns-sd -L "Wandi MacBook [f42dc1]" _klyndro._tcp local.` | **PASS** — `wandi-macbook.local.:47823`, `caps`, `fp` (64 hex), `id` (16 hex), `name`, `proto=1` |
| V14 | The macOS app launches as a menu bar agent and listens | `open Klyndro.app`, `pgrep` | **PASS** — process running; window shows the identity fingerprint |

### On-device verification — executed

| # | Claim | Command / evidence | Result |
| --- | --- | --- | --- |
| D1 | The debug APK installs and launches on HyperOS 3 / Android 15 | `adb install -r app-debug.apk`, `am start -n …/.MainActivity`, `pidof` | **PASS** |
| D2 | The Android UI renders correctly on the device | `adb exec-out screencap` (Home tab, dark theme) | **PASS** |
| D3 | The Android Keystore identity path works and is stable | `DeviceIdentityInstrumentedTest.keystoreIdentityIsCreatedAndReloadsWithTheSameFingerprint` | **PASS** — same fingerprint across reloads (UI showed `7d14c019`) |
| D4 | Deleting the Android identity is effective | `DeviceIdentityInstrumentedTest.deletingTheIdentityLeavesNoAlias` | **PASS** |
| D5 | The generated certificate is self-signed and valid | `DeviceIdentityInstrumentedTest.generatedCertificateIsSelfSignedAndValid` | **PASS** |
| D6 | Mutual TLS 1.3 with pinned keys works on the device runtime | `DeviceTransportInstrumentedTest.mutualTlsWithPinnedKeysAuthenticatesBothSidesOnDevice` | **PASS** — both sides cross-check the other's certificate over `127.0.0.1` |
| D7 | An untrusted certificate is refused on the device | `DeviceTransportInstrumentedTest.untrustedCertificateIsRefusedOnDevice` | **PASS** |
| D8 | Android NSD publishes a discoverable service on HyperOS | `DiscoveryInstrumentedTest.publishesAndBrowsesWithoutError` + `dns-sd -B _klyndro._tcp local.` on the Mac during the run | **PASS** — the Mac saw `Klyndro Android Test [2c7b1a]` |
| D9 | The published service type and port match the specification | `DiscoveryInstrumentedTest.publishedServiceTypeMatchesTheProtocolSpecification` | **PASS** |
| D10 | The Mac resolves the phone's TXT record and port | `dns-sd -L "Klyndro Android Test [2c7b1a]" _klyndro._tcp local.` during the run | **PASS** — `Android_UYJ1H0OU.local.:47823`, with `fp` (64 hex), `id` (16 hex), `caps`, `name`, `proto=1` |
| D11 | Android UI renders correctly after the tab-bar fix | `adb exec-out screencap` | **PASS** — "Home · Devices · Permissions · Settings" on one line, no clipped or wrapped labels |

Full `connectedDebugAndroidTest` run: **7 tests, 0 failures** (see `compatibility-matrix.md` for
the HyperOS install caveat that can make Gradle lie about this).

### Not executed

| # | Claim | Why not |
| --- | --- | --- |
| N1 | macOS ↔ Android pairing over a real network | Both halves are proven separately (Swift TLS loopback, on-device TLS loopback) but no cross-platform pairing session has run |
| N4 | macOS UI interactions (pairing sheet, unpair, diagnostics copy) | App launches; no UI test target exists |
| N5 | macOS Bonjour *browse* reacting to a live phone | Verified indirectly: `dns-sd` saw and resolved the phone, but the app's own browser was not observed rendering it |
| N6 | Wireless/USB reconnect timing with a real peer | No reconnect loop is wired yet (M4) |
| N7 | HyperOS autostart / battery behaviour | No background service exists yet (M4) |

### Device verification — still outstanding

A device is now attached, so these are unblocked *in principle* but not yet run. They need the
Android side to hold a connection, which does not exist until M2.

| Area | Why it cannot run yet | Status |
| --- | --- | --- |
| Pairing UI on the phone, six digits compared across devices | No pairing screen and no connection service on Android | **NOT TESTED** (M2) |
| Pairing window expiry / rate limit with two real devices | Same | **NOT TESTED** |
| Unpair then reconnect refused | Same | **NOT TESTED** |
| Manual IP fallback | Not in either UI | **NOT TESTED** |
| Clipboard, mirroring, notifications, files | Later milestones | **NOT TESTED** |

## M0 — foundation (still valid)

| # | Claim | Result |
| --- | --- | --- |
| V0.1 | Framing, envelope validation, state machine, backoff, toolchain probing | **PASS** |
| V0.2 | macOS app is a menu bar agent (`LSUIElement`) with an explicit `Info.plist` | **PASS** |
| V0.3 | Both platforms decode the shared fixtures identically | **PASS** |

## Feature status summary

| Feature | Implemented | Verified |
| --- | --- | --- |
| Device identity (key + self-signed cert) | Yes (both platforms) | **PASS** on macOS and on device (Keystore) |
| Pin policy / fingerprint pinning | Yes (both platforms) | **PASS** (unit + real TLS loopback on both stacks) |
| Mutual TLS 1.3 transport | Yes (both platforms) | **PASS** (macOS loopback, JVM loopback, on-device loopback) |
| Trust store | Yes (macOS Keychain; Android `EncryptedTrustStore` = SharedPreferences + `KeystoreSecretBox` AES-256-GCM, key in AndroidKeyStore) | **PASS** (macOS Keychain; Android JVM codec) — Android on-device persistence **BLOCKED** (device detached) |
| Session handshake (`hello`/`hello.ack`) | Yes (both platforms) | **PASS** (in-memory + TLS loopback) |
| Pairing (SAS, window, rate limit, persistence) | Yes (both platforms; macOS responder UI + `klyndro://pair`, Android initiator + Devices screen) | **PASS** (logic + in-memory end-to-end both platforms); first real-network attempt **FAIL** (`internal`), diagnosis **BLOCKED** (device detached) |
| Discovery | macOS advert+browse; Android NSD publish+browse | macOS advert **PASS** (`dns-sd -L`); Android publish **PASS** (seen by the Mac) |
| Reconnection wiring | Policy + state machine only | **NOT TESTED** (M4) |
| Clipboard sync | Yes (both platforms: engines + macOS `ClipboardSync`/`PasteboardMonitor`, Android `AndroidClipboard` + foreground loop + explicit send) | **PASS** (unit + cross-peer integration on macOS); on-device **BLOCKED** (device detached) |
| Mirroring, notifications, files | No | **NOT TESTED** (M3/M5) |

## Known gaps at M1

- No Android foreground service and no Android pairing screen: the Kotlin core and transport are
  complete and now verified *on* a device through instrumentation tests, but the app itself does
  not open a socket yet. That is M2 work.
- The macOS pairing sheet drives a real pairing session, but only the responder role is wired to
  the listener; initiating a pairing from the Mac to a discovered peer is not wired (the runner
  supports the initiator role and it is covered by tests).
- Manual IP entry is still absent from the UI (specified in F01).
- HyperOS refuses test-APK installs while the screen is locked, and `connectedDebugAndroidTest`
  reports `BUILD SUCCESSFUL` even when the install failed. Read the results XML, not the exit
  code.
- No UI tests on either platform.

## Corrections made during M1

Recorded because they show the tests doing their job:

1. `NWFrameTransport` did not declare `PeerKeyReporting`, so the handshake could never read the
   peer key. The TLS loopback test caught it with "peer key unavailable".
2. Frames arriving before `incoming()` was called were dropped, which stranded the handshake.
   Now buffered until a consumer attaches.
3. `NWFrameTransport.send` leaked a continuation when the connection was cancelled. Sends are
   now fire-and-forget, with failures surfacing through the receive stream.
4. The session's default close reason overwrote a recorded protocol violation. The default is
   now applied only when nothing was recorded.
5. `SecItemAdd` ignores `kSecAttrLabel` for certificates on macOS 27, so read-back by label
   always failed. The certificate DER is now stored separately (ADR 0008).
6. Fingerprints hashed the bare EC point instead of the DER SPKI, so local and TLS-observed
   fingerprints disagreed. Both are now hashed over the DER SPKI.

Defects found during the first hardware session:

7. The Android tab bar wrapped its labels ("Device s", "Permis sions"), shrinking the row. Labels
   are now single-line with ellipsis and the third tab was shortened to "Access".
8. Home still claimed "pairing arrives in milestone M1" after M1 shipped. Copy corrected on both
   the stale status line and the empty-devices card.
