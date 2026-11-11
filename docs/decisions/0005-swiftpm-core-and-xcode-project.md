# 0005 — macOS core as a SwiftPM library, project with synchronized groups

Status: Accepted (M0), implemented and verified

## Context

The macOS target needs testable logic (protocol, state machine, backoff, diagnostics) and a
SwiftUI shell. Options considered:

1. One app target with a unit-test bundle bound to the app as `TEST_HOST`.
2. A local SwiftPM library (`KlyndroKit`) plus a thin app target.
3. A SwiftPM-only app assembled into a bundle by a script.

## Decision

Option 2: `apps/macos/KlyndroKit` is a SwiftPM library with its own Swift Testing suite
(`swift test`), consumed by the app through a local package reference. The Xcode project is
hand-authored with the modern `PBXFileSystemSynchronizedRootGroup` object type
(`objectVersion = 77`), so files added under `Klyndro/` are picked up without project-file
edits.

## Consequences

- `swift test` runs the protocol suite with no simulator, no test host, and no signing —
  fast (≈0.5 s) and usable in CI.
- The app target stays small, so the hand-written project file stays small and stable. That
  matters because there is no project generator (XcodeGen is not installed, and adding a
  toolchain dependency for one project was not justified).
- Logic that must be tested goes in the kit; UI state stays in the app. `ToolchainProbe`
  followed this rule after initially living in the app target.
- Trade-off: adding a *second* app target (e.g. an XPC helper) means editing the pbxproj by
  hand. If that becomes routine, adopt XcodeGen or Tuist with an explicit decision.
- Signals to revisit: two or more test bundles, or UI tests that need a host app.
