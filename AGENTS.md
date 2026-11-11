# AGENTS.md

Instructions for anyone — human or agent — working in this repository.

## What this project is

Klyndro connects Android and macOS devices over the local network. Two native apps, one
specified protocol, no cloud. Read these before changing code:

1. [Architecture overview](docs/architecture/overview.md)
2. [Protocol specification](protocol/specification/klyndro-protocol-v1.md)
3. [Verification status](docs/testing/verification-status.md) — the truth about what works

## Non-negotiable constraints

- **Native UI only.** SwiftUI on macOS, Jetpack Compose on Android. No Electron, no web
  views for application UI.
- **Local-first.** No cloud service, account, relay, telemetry, or third-party analytics.
- **No custom cryptography.** Use TLS 1.3 from the platform. Do not invent key exchange,
  KDFs, ciphers, or "encryption" wrappers. Never store or log key material.
- **The protocol is owned by neither app.** Wire format changes start in
  `protocol/specification/` plus `protocol/fixtures/`, and both test suites must be updated
  in the same change.
- **Platform limits are documented, not worked around by pretending.** If a feature cannot
  work due to an OS restriction, say so in the docs and surface it in the UI.
- **Do not claim unverified behaviour.** Use the verification vocabulary below.

## Verification vocabulary

Every capability claim in docs, PRs, or UI copy must map to one of:

| Status | Meaning |
| --- | --- |
| `PASS` | Executed and observed working, with the command or test named |
| `FAIL` | Executed and observed broken, with the failure recorded |
| `BLOCKED` | Cannot execute due to an external constraint (e.g. no device attached) |
| `NOT TESTED` | Implemented or designed, but unverified |

A feature is never "done" without a `PASS` line in
[docs/testing/verification-status.md](docs/testing/verification-status.md).

## Repository conventions

| Path | Contents | Notes |
| --- | --- | --- |
| `apps/macos/KlyndroKit/` | Protocol, state machine, backoff, toolchain probing | Platform-level logic that must be unit-tested. Prefer landing logic here. |
| `apps/macos/Klyndro/` | SwiftUI app shell, views, app state | No protocol parsing. Views never do I/O directly. |
| `apps/android/app/src/main/kotlin/.../protocol/` | Wire format, mirrors KlyndroKit | Keep behaviour identical to Swift; shared fixtures enforce it. |
| `apps/android/app/src/main/kotlin/.../net/` | Connection state and backoff | Mirrors Swift. |
| `apps/android/app/src/main/kotlin/.../ui/` | Compose UI + ViewModel | Material 3, no navigation framework until screens are real. |
| `protocol/` | Spec + fixtures | Fixtures are consumed by both test suites. |
| `docs/decisions/` | ADRs | One decision per file, immutable once accepted; supersede instead of rewriting. |
| `scripts/` | Build/test entry points | Must run from a clean checkout. |

## Build and test commands

```bash
# Environment report (read-only)
./scripts/check-toolchain.sh

# macOS protocol tests (Swift Testing)
swift test --package-path apps/macos/KlyndroKit

# macOS app build
xcodebuild -project apps/macos/Klyndro.xcodeproj -scheme Klyndro -configuration Debug build

# Android JVM unit tests
cd apps/android && ./gradlew :app:testDebugUnitTest

# Android debug APK
cd apps/android && ./gradlew :app:assembleDebug
```

Both unit suites must pass before any milestone is reported complete.

## Coding standards

**Swift**

- Swift 6 language mode, strict concurrency. UI and app state on `@MainActor`.
- Value types for protocol logic (`struct`), so state machines are testable without I/O.
- No force-unwrapping outside tests. No empty `catch` blocks.
- Swift Testing (`@Test`, `#expect`) for tests, not XCTest.

**Kotlin**

- Kotlin official style, 4-space indent, trailing commas in multi-line calls.
- `sealed` hierarchies for protocol errors and events; `data class` for values.
- Coroutines and `Flow` for async work; no blocking calls on the main thread.
- JUnit 4 for JVM unit tests (no Robolectric until a test genuinely needs framework
  classes).

**Both**

- Comments explain *why*, not *what*. Do not restate the code.
- No logging of clipboard content, notification text, or secrets — at any level.
- New dependency? Justify it in the PR and prefer the platform SDK.

## Security rules

- Authenticated, encrypted transport for every session, including pairing.
- Reject rather than guess: unknown protocol version → close; oversized frame → close;
  unknown message *type* → ignore.
- Validate untrusted input before any side effect. Enforce size limits before allocating.
- Credentials live in Keychain (macOS) and Keystore-backed storage (Android). Never in
  `UserDefaults`, `SharedPreferences`, plists, logs, or fixtures.
- Never enable Accessibility, notification access, or other sensitive Android permissions
  silently. Ask, explain, and degrade gracefully if refused.
- Do not add network services that listen on untrusted networks with unauthenticated
  endpoints. The pairing listener is the only unauthenticated surface, and only for 60
  seconds on explicit user action.

## Workflow

1. Read this file, the architecture docs, and the verification status.
2. Confirm the milestone you are working in; do not pull later-milestone work forward.
3. Change the protocol first if the wire format changes, including fixtures.
4. Implement the smallest coherent increment; keep both apps buildable.
5. Build both targets; run both unit suites.
6. Record results honestly in `docs/testing/verification-status.md`.
7. Report: what changed, what was verified, what is blocked, what is next.

Never commit, push, or open a PR unless explicitly asked. Never delete user work. Never
install privileged tooling without telling the user what and why.
