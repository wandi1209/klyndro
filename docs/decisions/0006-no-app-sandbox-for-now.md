# 0006 — No App Sandbox for now; direct distribution

Status: Accepted (M0). Must be revisited before M6 release packaging.

## Context

The App Sandbox is the expected posture for a Mac app, but it restricts exactly what
Klyndro's mirroring feature does:

- Sandboxed apps cannot freely execute arbitrary external binaries (no `process-exec`
  entitlement for third-party tools), so launching the user's `/opt/homebrew/bin/scrcpy`
  with a child `adb` is not viable.
- The alternatives are (a) bundle `scrcpy` + `adb` inside the app and launch them with
  inherited sandbox entitlements — a large maintenance and licencing change, or (b) ship
  unsandboxed, as most developer/ADB-adjacent utilities do.

The practical open-source precedent for ADB-based tooling on macOS (device managers, ADB GUIs)
is direct, unsandboxed distribution rather than Mac App Store distribution.

## Decision

At M0 the app is **not sandboxed**. It is ad-hoc signed for local development
(`CODE_SIGN_IDENTITY = "-"`), with `ENABLE_HARDENED_RUNTIME = NO`. It is not distributed
from the Mac App Store.

## Consequences

- Mirroring can launch external tools without a sandbox exception dance.
- The app cannot be distributed through the Mac App Store in this configuration.
- Distribution will be a signed, notarised DMG (or Homebrew Cask) for M6. Hardened Runtime
  and notarisation are compatible with unsandboxed distribution; the plan is to enable
  Hardened Runtime at that point and keep the sandbox off.
- Users are asked to trust a binary that can execute processes. The mitigation is open
  source code, signed releases, and no network listeners beyond the paired-device session.
- Revisit trigger: if a bundled-helper design lands in M3, this ADR can be superseded and
  the app sandboxed with `com.apple.security.inherit` on the helpers.
