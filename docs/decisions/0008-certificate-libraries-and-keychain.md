# 0008 — Certificate generation libraries and Keychain storage layout

Status: Accepted (M1), implemented and verified on macOS; BouncyCastle path verified on the JVM.

## Context

ADR 0002 chose mutual TLS 1.3 with pinned self-signed certificates and left two questions open:

1. Which library builds the self-signed certificate on each platform?
2. Where does the identity actually live, given that neither platform offers a
   "create a self-signed identity" API?

Constraints from `AGENTS.md`: no custom cryptography, credentials in Keychain/Keystore, and a
preference for the platform SDK over new dependencies.

During M1 several platform behaviours were discovered empirically. They are recorded here
because they are not obvious from the documentation and each one changed the design.

## Decision

**Certificate encoding**

- macOS: `apple/swift-certificates` (`X509` product, Apache 2.0). It serialises the certificate
  and delegates every signature to a `SecKey` supplied by the caller, so the private key never
  leaves the Keychain and no primitive is implemented by us.
- Android: BouncyCastle `bcpkix-jdk18on` (MIT-style Bouncy Castle licence). `JcaX509v3CertificateBuilder`
  + `JcaContentSignerBuilder("SHA256withECDSA")`; signing goes through the JCA `Signature`
  engine backed by the key.

**Storage**

- macOS private key: permanent Keychain key with an application tag (login Keychain).
- macOS certificate: added as a Keychain certificate item so `SecIdentityCreateWithCertificate`
  can join it with the key, **and** its DER is stored as a generic-password item.
- Android: the key pair is stored in the `AndroidKeyStore` under a fixed alias, with the
  certificate stored alongside it.

## Findings that shaped the design

| Finding | Evidence | Consequence |
| --- | --- | --- |
| `SecItemAdd` for a certificate **silently ignores `kSecAttrLabel`** on macOS 27, so the item cannot be found by label afterwards | Spike: add returned 0, `SecItemCopyMatching` by label returned `-25300` | Trust must not depend on label lookup. The certificate DER is stored separately and read back to rebuild the `SecCertificate`. |
| The data-protection Keychain (`kSecUseDataProtectionKeychain`) fails with `-34018 errSecMissingEntitlement` for an ad-hoc-signed, unsandboxed app | Spike: generic-password read returned `-34018` | Both the identity and the trust store use the login Keychain. Moving to the data-protection Keychain requires a keychain-access-group entitlement, which requires proper signing (M6). |
| `sec_protocol_metadata_copy_peer_public_key` returns the **full DER SubjectPublicKeyInfo** (91 bytes for P-256), not the bare key point | Instrumented run: `bytes=91 head=30 59 30 13` | Fingerprints are hashed over the DER SPKI on both platforms. Hashing the bare point would make macOS and Android disagree. |
| `Certificate.PublicKey.subjectPublicKeyInfoBytes` returns only the **key point** (65 bytes), despite its name | Spike + test | The macOS fingerprint helper serialises the public key as DER explicitly (`serialize(into:withIdentifier:)`). |
| Network.framework does **not** start connections vended by `NWListener` | TLS loopback failed with "connection reset by peer"; trace showed `preparing` on both sides | `NWFrameTransport.startAccepted()` starts the connection and the receive loop. |
| TLS 1.3 lets the client reach `.ready` before the server has judged its certificate | Loopback test: client ready, server then failed | "Authenticated" is defined by the `hello` handshake, not by TCP/TLS readiness. The session layer is the gate. |

## Consequences

- Two dependencies added: `swift-certificates` (with `swift-crypto` transitively) on macOS and
  BouncyCastle on Android. Both are widely used, permissively licensed, and do ASN.1/X.509 only.
- The APK grows by roughly the size of BouncyCastle; acceptable for an application that would
  otherwise need to hand-roll ASN.1.
- `swift test` now resolves packages from the network on a clean checkout.
- The Android identity currently imports a generated key pair into the Keystore rather than
  using a non-exportable Keystore key. A non-exportable key requires a certificate bootstrap
  (self-signing with a Keystore key that cannot be exported works, but the trust-store migration
  and migration of existing installs need design). Tracked for M2, and the current behaviour is
  still compliant: the key never leaves Keystore-backed storage.
- Revisit trigger: adopting proper code signing (M6) makes the data-protection Keychain
  available; migrate then, and keep reading the login-Keychain location for one release.
