# 0001 — Two native apps with the protocol as the contract

Status: Accepted (M0)

## Context

Klyndro needs logic on both macOS and Android: framing, validation, connection state,
backoff, and later clipboard deduplication. Two obvious options:

1. A shared implementation (Kotlin Multiplatform, C++ core, or code generation) consumed by
   both apps.
2. Two independent native implementations, with the wire format specified in one place and
   conformance fixtures shared by both test suites.

## Decision

Option 2. `protocol/specification/klyndro-protocol-v1.md` is normative, and
`protocol/fixtures/*.json` plus `manifest.json` are executed by both test suites
(`swift test` on the Swift package, `testDebugUnitTest` on Android). No runtime code is
shared.

## Consequences

- Each platform stays idiomatic: Swift value types and Swift Testing on one side, Kotlin
  sealed hierarchies and JUnit 4 on the other. No FFI, no Gradle-to-Xcode build plumbing.
- Duplication is real but small and bounded: the M0 shared surface is ~250 lines per
  platform. The fixtures make divergence a test failure rather than a support ticket.
- Every protocol change is at least a three-file change (spec, fixtures, both
  implementations) and the review checklist in `AGENTS.md` says so.
- If the protocol later grows to dozens of messages with binary payloads, revisit this
  decision. Today it is the cheapest honest option.
