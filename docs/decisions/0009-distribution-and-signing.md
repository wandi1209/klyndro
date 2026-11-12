# 0009 — Distribution and signing

Status: Accepted (M6). Supersedes the "Revisit before M6" note in ADR 0006; the sandbox decision
itself is unchanged.

## Context

M0 shipped ad-hoc signed debug builds. M6 needs a documented way to produce installable artefacts
without putting secrets in the repository or claiming trust we cannot back.

## Decision

- **macOS:** unsandboxed, direct distribution as zip + DMG. Default signature is ad-hoc.
  Developer ID signing with Hardened Runtime is selected with `KLYNDRO_SIGN_IDENTITY`;
  notarisation is a separate manual step. Mac App Store is out of scope (ADR 0006).
- **Android:** signed APK, not AAB. The keystore path and passwords come from `KLYNDRO_*`
  environment variables; without them the build produces an explicitly named UNSIGNED APK.
- R8 shrinking is on for release builds. Keep rules are minimal because wire messages use
  `JsonObject`, not reflective binding.
- Release artefacts are written to the gitignored `dist/`, with SHA-256 printed.

## Consequences

- No Developer ID identity exists on the development machine, so notarisation and Developer ID
  signing are documented, not verified.
- Changing the macOS signing identity changes Keychain access; first Developer ID build requires
  re-pairing (see `docs/development/release.md`).
- The Android signing key is a single point of failure for upgrades and must be backed up.
- Moving to the data-protection Keychain (ADR 0008) stays deferred until a team identifier and a
  keychain-access-group entitlement exist.
