# Verification status

The single source of truth for what has actually been executed. Last updated: **2026-11-12**
(M6). Notification forwarding & file transfer (M5), background autoconnect (M4), screen mirroring (M3),
bidirectional clipboard (M2), and mutual TLS pairing (M1) are verified on real hardware.

Device under test: Xiaomi Redmi Note 13 5G (`2312DRAABG`, codename `iron`), HyperOS 3.0
(`OS3.0.3.0.VNQIDXM`), Android 15 (API 35), arm64-v8a, attached over USB as
`hiam6hf6lfsshuif`.

Vocabulary: `PASS` executed and observed working · `FAIL` executed and observed broken ·
`BLOCKED` cannot execute (external constraint) · `NOT TESTED` implemented/designed but
unverified.

## M6 — release engineering, brand, security review

| # | Claim | Result |
| --- | --- | --- |
| M6-B1 | macOS Release build with app icon asset catalog | **PASS** — `./scripts/release-macos.sh` builds Release; `AppIcon.icns` and `Assets.car` present in the Debug bundle |
| M6-B2 | macOS ad-hoc signature valid, zip + DMG produced | **PASS** — `codesign --verify --deep --strict` clean; `Klyndro-macOS-0.1.0.zip/.dmg` written |
| M6-B3 | Android release build with R8 and resource shrinking | **PASS (build)** — `assembleRelease` succeeds, APK 4.6 MB (debug 36.7 MB) |
| M6-B4 | Android release APK signed from external keystore | **PASS** — throwaway key, `apksigner verify` OK (v2 scheme) |
| M6-D1 | Minified release APK runs on the device and connects | **NOT TESTED** — installing over the debug build would uninstall it and delete the phone's pairing; not done without user approval |
| M6-D2 | macOS Hardened Runtime build runs and connects | **PASS** — copy of the Release app signed with `codesign --options runtime` (`flags=adhoc,runtime`) advertised `_klyndro._tcp`, listened on 47823 and connected to the phone (`Status: connected`). Caveat: the phone's first attempt had failed (`ECONNREFUSED`, from the previous app instance) and did not retry by itself within about 45 s; it connected after Stop then Start on the phone. Notarised/Developer ID signing is still **BLOCKED** |
| M6-D3 | Developer ID signing and notarisation | **BLOCKED** — no Developer ID identity on this machine |
| M6-W1 | Mirroring finds and connects the phone over Wi-Fi automatically, no USB | **PASS** — see `docs/architecture/mirroring.md`. Pairing form **NOT TESTED** |
| M6-D1b | Minified release APK pairs and connects with the Mac | **PASS** — fingerprint `8bbaa632` shown as Connected on the Mac |
| M6-D1c | Release APK clipboard, both directions | **PASS** — `pbcopy` on the Mac raised `Received from Mac` and the phone clipboard held the text; text sent from the phone arrived in `pbpaste`. Phone app in the foreground, Wi-Fi adb |
| M6-D1d | Release APK reconnects after Wi-Fi loss | **PASS** — phone Wi-Fi off 8 s then on; Klyndro showed `Status: connected` again within 15 s without any tap. One run only |
| M6-W2 | Popup explaining Wireless / USB debugging when mirroring cannot start | **PASS** — 3 unit tests, plus manual confirmation by the user that the popup shows and mirroring starts once Wireless debugging is on |
| M6-F1 | Android file receiver: size cap, in-order chunks, hash check, name sanitising | **PASS** — 14 JVM tests (`FileReceiveSessionTest`) |
| M6-F2 | Mac file sender: offer/accept/reject, ordered chunks, hash | **PASS** — 7 tests (`FileTransferSenderTests`) |
| M6-M1 | Mirror raw-input scoping: mirror challenge/proof binds adb serial to paired phone | **PASS** — 18 unit tests (`MirrorProofTests`, `MirrorProofResponderTest`) + verified on Redmi Note 13 5G (`hiam6hf6lfsshuif`, Debug build): connected session verifies and cleans up `/sdcard/Android/data/id.my.wandidev.klyndro/files/klyndro-mirror-proof` before launching `scrcpy`; disconnected phone (`Status: stopped`) is refused (fixed fail-open `verifySerial = nil` bug in `AppModel`). Two-device mismatch on hardware **NOT TESTED** (single phone attached; covered in unit tests) |
| M6-U1 | New logo shown on the Android Home screen, live status pill, dark-mode text | **PASS** — screenshot on Redmi Note 13 5G |
| M6-U2 | Menu bar icon, Dock icon, Mac main window, Android launcher icon | **NOT TESTED** — Mac menu bar not reachable by script, launcher screenshot did not show the icon |
| M6-S1 | `scripts/audit-repo.sh` guard checks | **PASS** — 9 checks |
| M6-S2 | Security review | See [review checklist](../security/review-checklist.md): S11 **PASS** (scoped via challenge/proof; two-device hardware mismatch NOT TESTED), 2 partial/NOT TESTED (S9, S12 Developer ID) |

## M5 — notification forwarding & file transfer

Notification forwarding (`NotificationListenerService` -> `UNUserNotificationCenter`) with 5-minute
deduplication, and chunked local-network file transfer (`file.offer` -> `file.chunk` ->
`file.complete`) with SHA-256 integrity verification and filename conflict resolution.

| # | Claim | Result |
| --- | --- | --- |
| M5-V1 | Notification & file protocol codecs + fixture conformance tests | **PASS** — 5 new Swift tests (183 total in 28 suites), Android `NotificationMessagesTest` passing |
| M5-D1 | Android notification forwarded to macOS Notification Center | **PASS** — `cmd notification post` captured by `KlyndroNotificationListener`, sent (`sent: true`), and presented as banner by `usernoted` |
| M5-D2 | Android -> Mac file transfer with SHA-256 verification | **PASS** — 301 KB image sent from Redmi Note 13 5G, saved to `~/Downloads/` with identical SHA-256 (`1fad05d6541...`) |
| M5-N1 | Mac -> Android file transfer | **PASS** (M6) — 3,000,000 random bytes sent from the Mac app, saved on the phone to `Download/Klyndro/` with an identical SHA-256 (`669ba057c3cb…bf45`). Release APK, Wi-Fi. One file, one run; large files and a rejected offer were not exercised on a device |

## M4 — background integration & autoconnect

Auto-reconnect on both sides: Android foreground service automatically dials paired Mac via mDNS
on app resume and reconnects with exponential backoff on disconnect; macOS monitors network paths
(`NWPathMonitor`) and handles sleep/wake (`NSWorkspace.didWakeNotification`), plus `SMAppService`
launch-at-login settings integration.

| # | Claim | Result |
| --- | --- | --- |
| M4-D1 | Android auto-connects to paired Mac on app open without tapping "Start connection" | **PASS** — verified in logcat: `dialing pinned peer at 192.168.23.101:47823` -> `session established with Wandi MacBook` -> status `connected` |
| M4-D2 | Clipboard sync works immediately after auto-connect | **PASS** — `pbcopy` on Mac immediately updated phone clipboard preview |
| M4-D3 | Android reconnects with bounded exponential backoff on peer disconnect | **PASS** — `ReconnectPolicy` delay calculated and scheduled on `PeerSessionEvent.Closed` |
| M4-V1 | macOS network path monitor (`NWPathMonitor`) & sleep/wake listener restart | **PASS** — wired in `AppModel` |
| M4-V2 | macOS `SMAppService.mainApp` launch at login setting integration | **PASS** — `LaunchAtLogin.swift` with `.app` bundle detection |

## M3 — screen mirroring (scrcpy)

USB mirroring works from the app on the Redmi Note 13 5G. Full table with evidence is in
[mirroring.md](../architecture/mirroring.md#verification-results).

| # | Claim | Result |
| --- | --- | --- |
| M3-V1 | 19 new unit/process tests (parser, argument builder, ring buffer, state machine with fake child scripts) | **PASS** — suite is now 167 tests in 25 suites |
| M3-D1 | Start from the app over USB; scrcpy is a child of Klyndro | **PASS** |
| M3-D2 | Mac mouse and keyboard control the phone | **PASS** — tab switched by click; `hi` typed into a phone field |
| M3-D3 | Rotate, resize | **PASS** |
| M3-D4 | Stop and quit leave no scrcpy or scrcpy-server process | **PASS** |
| M3-D5 | adb lost mid-session: process cleaned up, app survives | **PASS** (UI failure text NOT TESTED) |
| M3-D6 | Wireless mirroring over Wi-Fi (adb connect endpoint) | **PASS** — child process launched, mouse control confirmed |
| M3-D7 | Screen-off mode (`--turn-screen-off`) | **PASS** — verified dark panel by user on physical device |
| M3-N1 | Fullscreen | **NOT VERIFIED** |
| M3-N2 | Wireless mirroring via `adb tcpip 5555` | **NOT TESTED** — avoided in favour of Android 11+ Wireless Debugging |
| M3-N4 | Scoping mirroring to Klyndro-paired devices | **PASS** (M6) — `mirror.challenge`/`mirror.proof` (§5.4a) binds adb serial to the paired Klyndro session; verified on device when connected and refused when disconnected |

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

### On-device verification — executed on the Redmi Note 13 5G

| # | Claim | Evidence | Result |
| --- | --- | --- | --- |
| M2-D1 | macOS ↔ Android pairing over a real network, six-digit code compared on both devices | Phone showed the code dialog; "Codes match" persisted the peer on both sides. Mac login keychain item `id.my.wandidev.klyndro.trust` and the phone's `paired_peers_sealed` both held the peer afterwards | **PASS** — the earlier `internal` failure had three causes, all fixed: listener rebinding raced `Address already in use`; `startAccepted()` handed the transport to `PairingRunner` before TLS was `.ready`; the Mac advertised only link-local IPv6 |
| M2-D2 | Clipboard instrumented test on HyperOS (focused write→read, `EXTRA_IS_SENSITIVE`) | `AndroidClipboardInstrumentedTest`, run via `am instrument` with the Activity in front | **PASS** — only when the operation runs on the focused Activity's UI thread. From the test thread HyperOS logs `Denying clipboard access … application is not in focus` |
| M2-D3 | Android → Mac clipboard from a real copy made in another app (WhatsApp), no button pressed | Copy in WhatsApp, return to Klyndro: counter `Sent to Mac` 5 → 6 and `pbpaste` returned the copied text | **PASS** |
| M2-D4 | Mac → Android clipboard | `pbcopy` on the Mac: `Received from Mac` incremented and the in-app preview matched | **PASS** |
| M2-D5 | Explicit "Send text to Mac instead" path | Typed text sent; `pbpaste` changed from a reset marker to the typed text | **PASS** |
| M2-D6 | Sealed trust-store round trip on HyperOS (`AndroidKeyStore` AES-256-GCM) | `EncryptedTrustStoreInstrumentedTest`, 3 tests | **PASS** — exonerated: the trust store was not the cause of the earlier `internal` |
| M2-D7 | Pinned reconnect over Wi-Fi after the USB tunnel is gone | Stored address `127.0.0.1` refused; the mDNS fallback dialled the Mac's LAN IPv4 and the phone reached `Status: connected` | **PASS** |
| M2-D8 | Loop suppression on a real network | Copy on Mac: phone `Received` 3 → 4, `Sent` stayed 6 for 14 s, Mac clipboard unchanged. Reverse direction: `Sent` stayed 6 for 16 s after the Mac received the phone's text | **PASS** |
| M2-D9 | Full on-device instrumented suite | `am instrument` over all classes: 11 tests | **PASS** |

### Still NOT TESTED (M2 scope)

| Area | Why it matters |
| --- | --- |
| Phone app in background / screen off | Designed to stop syncing (Android grants clipboard only to the focused app). The in-app message has not been checked against the real behaviour |
| HyperOS autostart and battery restrictions | Belongs to M4; nothing exercises process death yet |
| Reconnect after Mac sleep/wake or a Wi-Fi change | No automatic reconnect loop exists yet (M4); a manual Stop/Start was used |
| Sensitive-clip gating end to end | Unit-tested; the on-device test only proves the flag is readable |
| Clipboard content over 256 KiB | Unit-tested only |

### Known defects found during device verification (open)

- The pairing sheet on macOS cannot be dismissed after a failure was fixed in code, but the fix was
  only exercised by rebuilding and re-pairing, not by a UI test.
- Stored `lastHost` is whatever address was used to pair. A USB pairing stores `127.0.0.1`, which
  goes stale; the reconnect fallback masks this rather than correcting the stored address.
- On macOS the paired phone's stored `lastHost`/`lastPort` is the phone's ephemeral source port and
  is not usable for dialling. The Mac never dials today, so it is harmless, but it is wrong data.
- Stopping the Android service clears discovery, and the next start dials before mDNS resolves.
  The 20 s poll added in `startConnecting()` covers it; a persistent browse would be cleaner.

### Re-running the device checks

1. Keep the phone unlocked (`adb shell settings put global stay_on_while_plugged_in 2`); HyperOS
   refuses installs while locked.
2. Run the macOS app from a DEBUG build with `launchctl setenv KLYNDRO_AUTOCONFIRM_PAIRING 1`.
3. Phone: Devices tab → wait for the Mac to appear → Pair. Mac: `open klyndro://pair` first (60 s).
4. Once `Status: connected`: `pbcopy` on the Mac must raise `Received from Mac`; text copied in
   another app must arrive via `pbpaste` while Klyndro is on screen.
5. Instrumented tests: `am instrument -w id.my.wandidev.klyndro.test/androidx.test.runner.AndroidJUnitRunner`
   with the app in front. If you use Gradle's `connectedDebugAndroidTest` instead, read
   `app/build/outputs/androidTest-results/connected/debug/*.xml`; the exit code can lie.

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
| Trust store | Yes (macOS Keychain; Android `EncryptedTrustStore` = SharedPreferences + `KeystoreSecretBox` AES-256-GCM, key in AndroidKeyStore) | **PASS** (macOS Keychain; Android JVM codec; Android on-device seal/open/reload, 3 tests) |
| Session handshake (`hello`/`hello.ack`) | Yes (both platforms) | **PASS** (in-memory + TLS loopback) |
| Pairing (SAS, window, rate limit, persistence) | Yes (both platforms; macOS responder UI + `klyndro://pair`, Android initiator + Devices screen) | **PASS** (logic + in-memory end-to-end both platforms, and a real Mac↔phone pairing). Window expiry and rate limit with real devices **NOT TESTED** |
| Discovery | macOS advert+browse; Android NSD publish+browse | macOS advert **PASS** (`dns-sd -L`); Android publish **PASS** (seen by the Mac) |
| Reconnection wiring | Policy + state machine only | **NOT TESTED** (M4) |
| Clipboard sync | Yes (both platforms: engines + macOS `ClipboardSync`/`PasteboardMonitor`, Android `AndroidClipboard` + foreground loop + explicit send) | **PASS** (unit + cross-peer integration, and both directions on the Redmi Note 13 5G while the app is on screen). Background / screen-off **NOT TESTED** |
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
