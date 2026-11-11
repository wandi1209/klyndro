# 0002 — TLS 1.3 with pinned self-signed certificates

Status: Accepted (M0). Certificate generation libraries are still to be chosen in M1.

## Context

Every session must be authenticated and encrypted, including the first one. The candidates
were:

1. **TLS 1.3 with mutual authentication**, using a self-signed certificate per device and
   pinning the peer's SPKI SHA-256 fingerprint after pairing.
2. **Noise protocol** (XX/KK) with a Swift and a Kotlin implementation.
3. **Application-level handshake** from primitives (X25519 + HKDF + ChaChaPoly).

## Decision

Option 1. Both platform SDKs ship TLS 1.3 and configurable trust evaluation; we write no
cryptography. Pin the peer's SPKI fingerprint in the trust store; the certificate chain has
no PKI role.

## Consequences

- No custom key exchange, KDF, or cipher code — the repository rule in `AGENTS.md`.
- Self-signed certificate *creation* still needs an X.509 builder: `swift-certificates`
  (Apple) on macOS and BouncyCastle on Android are the candidates. Both add a dependency and
  must be justified and reviewed in M1 before use. Keys themselves come from
  `SecKeyCreateRandomKey` and the Android Keystore.
- Pinning happens at the fingerprint level, so a legitimate certificate re-issue requires
  re-pairing. That is the safe default and is documented in the pairing design.
- 0-RTT is disabled: clipboard updates are side effects and must not be replayable.
- Noise would have avoided X.509 entirely, but there is no first-party Noise
  implementation on either platform, so we would own the framing and the review burden of a
  hand-rolled handshake composition. Rejected.
