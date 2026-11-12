# Security review (M6)

Review of the `AGENTS.md` security rules against the code at the M6 commit. "Evidence" names the
command or file that supports each line. `./scripts/audit-repo.sh` automates the grep-level
guards; the rest was read by hand. This is a self-review by the authors, not an independent
audit.

| # | Rule | Result | Evidence |
| --- | --- | --- | --- |
| S1 | No cloud service, account, relay, telemetry or analytics | **PASS** | `audit-repo.sh` finds no analytics SDK in the dependency manifests. Android dependencies are AndroidX, Compose, Gson, BouncyCastle, coroutines |
| S2 | No custom cryptography | **PASS** | TLS 1.3 from the platform; BouncyCastle/swift-certificates only encode X.509. The single `Cipher` use is `KeystoreSecretBox` (platform AES-GCM, non-exportable Keystore key), allow-listed in the audit |
| S3 | Credentials only in Keychain / Keystore | **PASS** | macOS identity and trust in Keychain (ADR 0008); Android identity in Keystore-backed storage. Audit finds no credential writes to `UserDefaults` / `SharedPreferences` |
| S4 | No key material in the repo, logs or fixtures | **PASS** | Audit scans for PEM private keys and tracked `.jks/.p12/.pem`; none. `.gitignore` blocks keystores and `dist/` |
| S5 | No clipboard or notification content in logs | **PASS** | Audit greps both trees. Android `KlyndroNotificationListener` logs app name, a `package:id:time` key and the connection phase, never title or text. That log line is a deliberate, reviewed exception |
| S6 | Authenticated, encrypted transport for every session including pairing | **PASS (by test)** | Mutual TLS 1.3 with pinned SPKI; pairing adds a six-digit SAS. Unit tests and on-device pairing (M1) |
| S7 | Unknown protocol version closes; oversized frame closes; unknown message type ignored | **PASS (by test)** | Envelope and frame unit tests on both platforms, shared fixtures |
| S8 | Size limits enforced before allocation | **PASS (by test)** | Frame length check precedes buffer allocation; covered by frame tests. File transfer verifies SHA-256 on completion |
| S9 | Only unauthenticated surface is the pairing listener, 60 s, on user action | **PASS** | Window length is in code and unit tests (`PairingWindow.defaultDuration == 60`). Observed on Redmi Note 13 5G + Debug Mac app: `klyndro://pair` opened at `11:05:20`, `closePairingWindow()` switched listener back to `.pinned` at `11:06:21.507`, and tapping `Pair` at `11:06:35` was rejected (`[C2]` cancelled) |
| S10 | Sensitive Android permissions never enabled silently | **PASS** | Notification access is opened through system settings by user tap; the app never requests Accessibility. `PermissionsScreen` shows real state |
| S11 | Mirroring is limited to Klyndro-paired devices | **PASS** | Protocol §5.4a (`mirror.challenge`/`mirror.proof`) binds the adb serial to the active Klyndro TLS session and fails closed when disconnected. Verified by 18 unit tests and on Redmi Note 13 5G (connected allowed, disconnected refused); two-device hardware mismatch **NOT TESTED** |
| S12 | Mac app runs under Hardened Runtime for distribution | **PASS (ad-hoc)** | Release app re-signed with `--options runtime` launched, advertised over Bonjour and held a session with the phone. Not tested with a Developer ID or after notarisation |
| S13 | Release Android build is shrunk and signed from external secrets | **PASS** | `assembleRelease` succeeds with R8; `apksigner verify` passes; `v0.1.0` CI-signed APK (`CN=Klyndro`) installed and verified on Redmi Note 13 5G (pairing, bidirectional clipboard, mirror scoping) |
| S14 | Mac app is not sandboxed | **ACCEPTED RISK** | ADR 0006: needed to launch scrcpy/adb. Mitigation: open source, signed releases, no listeners other than the paired session |

## Known weaknesses

- Ad-hoc signed macOS builds carry no publisher identity. Users must verify the SHA-256 against a
  value published through a separate channel.
- A pairing made over the USB path previously stored `127.0.0.1` as last host; fixed via
  `PeerAddressPolicy` (`ManualEndpointTest` **PASS** and verified on Redmi Note 13 5G).
- Notification text is forwarded in clear *inside* the TLS session; it is shown by macOS and
  subject to the user's Notification Center settings.
