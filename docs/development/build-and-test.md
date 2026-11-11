# Build and test

## Commands

| Task | Command |
| --- | --- |
| Environment report | `./scripts/check-toolchain.sh` |
| Swift tests only | `swift test --package-path apps/macos/KlyndroKit` |
| macOS app build | `xcodebuild -project apps/macos/Klyndro.xcodeproj -scheme Klyndro -configuration Debug build` |
| Both macOS steps | `./scripts/build-macos.sh` |
| Android JVM tests only | `cd apps/android && ./gradlew :app:testDebugUnitTest` |
| Android debug APK | `cd apps/android && ./gradlew :app:assembleDebug` |
| Both Android steps | `./scripts/build-android.sh` |
| Both unit suites | `./scripts/test-all.sh` |
| Android on-device tests | `./scripts/test-device.sh` (needs an attached, unlocked phone) |

Release builds (`-configuration Release`, `assembleRelease`) are intentionally not part of
M0: signing and packaging are M6 work.

## What the macOS side builds

- `apps/macos/KlyndroKit` — SwiftPM library, `swift-tools-version: 6.0`, Swift 6 language
  mode, minimum macOS 14. It owns protocol framing, envelope validation, the handshake,
  device identity and pinning, the pairing window and runner, the connection state machine,
  reconnect policy, Bonjour discovery, and toolchain probing.
- It depends on Apple's `swift-certificates` (product `X509`) to DER-encode the self-signed
  identity certificate; the signature is produced by a Keychain `SecKey`. First build resolves
  the package from the network (ADR 0008).
- `apps/macos/Klyndro.xcodeproj` — the app target. `project.pbxproj` uses
  `objectVersion = 77` with a file-system-synchronized group, so new files under
  `apps/macos/Klyndro/` are compiled without editing the project. The app depends on the
  local package (`XCLocalSwiftPackageReference` → `KlyndroKit`).
- Test target: the package's tests, run with `swift test`. There is no app-hosted test
  bundle at M0.

## What the Android side builds

- `apps/android` — Gradle 9.7.1 via the Wrapper, AGP 9.5.1, `compileSdk = 37`,
  `minSdk = 29`, `targetSdk = 36`.
- Built-in Kotlin (AGP 9) means **no** `kotlin-android` plugin. The Compose compiler plugin
  is pinned to 2.2.10, the Kotlin version AGP 9.5.1 bundles.
- `implementation` dependencies: AndroidX core-ktx, activity-compose, lifecycle
  runtime/viewmodel compose, Compose BOM 2026.09.00 (ui + material3), Gson, BouncyCastle
  `bcpkix-jdk18on` + `bcprov-jdk18on` (X.509 encoding only), and kotlinx-coroutines-core.
- BouncyCastle ships duplicate `META-INF/LICENSE.md` files; `packaging.pickFirsts` keeps one
  copy rather than dropping the attribution.
- `testImplementation`: JUnit 4.13.2. JVM unit tests only — no Robolectric, because the code
  under test is pure Kotlin.

## Tests and what they protect

| Suite | File | Protects |
| --- | --- | --- |
| Frame codec (Swift/Kotlin) | `FrameCodecTests` / `FrameCodecTest` | Length prefix, split reads, coalesced frames, size limits, unknown kinds |
| Envelope codec | `EnvelopeTests` / `EnvelopeCodecTest` | Required fields, UUID validation, version rejection, unknown types, UTF-8 strictness |
| Fixture conformance | `FixtureConformanceTests` / `FixtureConformanceTest` | Both platforms decode `protocol/fixtures` identically |
| State machine | `ConnectionStateMachineTests` / `ConnectionStateMachineTest` | Valid/invalid transitions, failure accounting |
| Backoff | `ReconnectPolicyTests` / `ReconnectPolicyTest` | Exponential growth, cap, jitter band, monotonicity |
| Toolchain probe (Swift only) | `ToolchainProbeTests` | Binary lookup and version summarisation |
| Identity (Swift) | `CryptoTests`, `IdentityAndTrustTests` | SPKI fingerprints, Keychain create/load/delete, pin decisions |
| Pairing (Swift) | `HandshakeAndPairingTests`, `PairingRunnerTests` | SAS vectors, window/rate limits, forged-fingerprint rejection, mutual confirmation |
| Transport (Swift) | `TLSIntegrationTests` | Real mutual TLS 1.3 on loopback: pin accept and reject |
| Discovery (Swift) | `DiscoveryTests` | TXT codec, advertisement parsing, name caps |
| Primitives (Kotlin) | `PrimitivesTest` | Same SAS vector as Swift (independently generated), fingerprints |
| Identity + pinning (Kotlin) | `PinPolicyTest` | Certificates generated with BouncyCastle, accept/reject matrix |
| Handshake + pairing (Kotlin) | `HandshakeTest` | Validation order, negotiation, message round trips |
| Session (Kotlin) | `PeerSessionTest` | Handshake, violations, timeout, unknown types |
| Transport (Kotlin) | `TlsLoopbackTest` | Real JSSE mutual TLS 1.3: pin accept, reject, pairing window |

Run one suite:

```bash
swift test --package-path apps/macos/KlyndroKit --filter FrameCodec
cd apps/android && ./gradlew :app:testDebugUnitTest --tests '*FrameCodecTest'
```

### Shared vectors, not shared code

`protocol/vectors/pairing-sas.json` contains a pairing-code vector computed with Python's
`hashlib`, i.e. by neither implementation. Both suites must reproduce it. If the two apps ever
disagree about the six digits a user compares, that test fails on both sides.

## Changing the protocol

The protocol is a shared contract. A wire-format change is one atomic change across four
places:

1. `protocol/specification/klyndro-protocol-v1.md` — normative text and limits.
2. `protocol/fixtures/` — add or update a JSON example.
3. `protocol/fixtures/manifest.json` — declare the expected decoder outcome
   (`valid`, `unknown_type`, or `malformed`).
4. Both implementations and both test suites.

The conformance tests assert that the manifest lists exactly the fixtures on disk, so a new
fixture without a manifest entry fails the build on both platforms.

## Device testing

Unit tests cannot cover the Android Keystore, the device's TLS stack, or `NsdManager`. Those are
covered by instrumentation tests in `apps/android/app/src/androidTest/`:

| Class | Covers |
| --- | --- |
| `DeviceIdentityInstrumentedTest` | Keystore identity creation, stable fingerprint across reloads, deletion, certificate validity |
| `DeviceTransportInstrumentedTest` | Real mutual TLS 1.3 over the device loopback; pin accept and reject |
| `DiscoveryInstrumentedTest` | NSD publish + browse; holds the advertisement open for an external observer |

Run them with `./scripts/test-device.sh`. Two HyperOS behaviours matter:

1. **The screen must be unlocked.** A locked device fails the install with
   `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`.
2. **Gradle's exit code can lie.** `connectedDebugAndroidTest` has printed
   `AndroidTestRunner failed … INSTALL_FAILED_USER_RESTRICTED` and still reported
   `BUILD SUCCESSFUL`. Always read
   `apps/android/app/build/outputs/androidTest-results/connected/debug/*.xml`.

To verify discovery from the other side, hold the phone's advertisement and browse from the Mac:

```bash
./scripts/test-device.sh -Pandroid.testInstrumentationRunnerArguments.class=id.my.wandidev.klyndro.DiscoveryInstrumentedTest &
sleep 45
dns-sd -B _klyndro._tcp local.
```

Manual, cross-device tests are listed in [the test plan](../testing/test-plan.md) and their
results in [verification status](../testing/verification-status.md). Do not mark a device test
as passing without attaching a phone.

## Troubleshooting the build

- **`swift test` cannot find fixtures** — the test locates `protocol/fixtures` by walking up
  from `#filePath`. If you move the test file, update the hop count in
  `FixtureConformanceTests.fixturesDirectory`.
- **Android fixtures not found** — `FixtureConformanceTest` searches
  `../../../protocol/fixtures` relative to the Gradle test working directory (the `app`
  module). It reports the directory it searched on failure.
- **Xcode cannot resolve KlyndroKit** — the package reference is relative
  (`relativePath = KlyndroKit`), so the project must be opened from
  `apps/macos/Klyndro.xcodeproj` in place, not copied elsewhere.
- **Code signing errors** — the project uses ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`,
  `CODE_SIGN_STYLE = Manual`, empty team). Verify with
  `codesign -dv path/to/Klyndro.app`; `Signature=adhoc` is expected for development.
