# Klyndro Protocol — Version 1 (Draft)

Status: **design specification, partially implemented**

| Part | Status |
| --- | --- |
| Framing | Implemented and tested in Swift and Kotlin (M0) |
| Envelope + JSON model | Implemented and tested in Swift and Kotlin (M0) |
| `hello` / `hello.ack` / `ping` / `pong` | Implemented and tested in Swift and Kotlin (M1) |
| Pairing / SAS | Implemented and tested in Swift and Kotlin (M1); not yet exercised device-to-device |
| Discovery (mDNS) | Specified and implemented (M1); macOS verified with `dns-sd`, Android BLOCKED |
| Clipboard messages | Specified, **not implemented** (M2) |
| File transfer chunking | Reserved, **not implemented** (M5) |

This document is the normative contract between the macOS and Android apps. Neither
app owns the protocol; the fixtures in [`../fixtures`](../fixtures) are the shared
executable reference for the parts marked as implemented.

## 1. Design goals

1. Communication stays on the local network. No account, no cloud, no relay.
2. Both endpoints are authenticated. There is no unauthenticated command surface.
3. The wire format is simple enough to implement twice, from scratch, in two
   languages, without sharing generated code.
4. Every byte on the wire is bounded. No field is "as large as the sender wants".
5. Unknown *types* are forward compatible; unknown *versions* are not guessed at.

Non-goals for v1: multi-hop routing, internet relay, offline message queues,
multiple concurrent user sessions on one device.

## 2. Transport

| Property | Value |
| --- | --- |
| Base transport | TCP |
| Port | 47823 (advertised via mDNS; the listener may bind an ephemeral port and advertise it) |
| Security layer | TLS 1.3 only, mutual authentication |
| Certificates | One self-signed ECDSA P-256 certificate per device, generated on first run |
| Trust model | Certificate pinning of the peer's SPKI SHA-256 fingerprint, established during pairing |
| Idle heartbeat | `ping` every 15 s, `pong` expected |
| Peer considered dead | 45 s without any traffic |
| Max concurrent connections | 4 (one session per trusted device; extra connections are closed with `busy`) |

Both peers MUST reject a connection if the presented certificate fingerprint does not
match a pinned fingerprint for the peer's advertised device ID. See
[../docs/architecture/pairing-and-security.md](../docs/architecture/pairing-and-security.md).

TLS 1.3 provides confidentiality, integrity and forward secrecy. Certificate pinning
is what provides *authentication*; TLS alone with self-signed certificates would allow
any device on the LAN to connect.

## 3. Framing

Every frame is:

```text
+----------------+------------+--------------------+
| uint32 length  | uint8 kind | byte[length - 1]   |
| (big endian)   |            |                    |
+----------------+------------+--------------------+
```

| Field | Rule |
| --- | --- |
| `length` | Number of bytes **after** the length field. MUST be in `[1, 1048576]`. |
| `kind` | `0x01` = JSON envelope, `0x02` = reserved for file chunk (not in v1). |
| payload | `length - 1` bytes. For `kind = 0x01` this is UTF-8 JSON. |

Implementation requirements:

- A peer that sends `length < 1` or `length > 1048576` MUST be disconnected with error
  `protocol.frame_too_large` (or `protocol.malformed` for `length < 1`); the length is
  never used to allocate memory before the bound is checked.
- A peer that sends an unknown `kind` MUST be disconnected with
  `protocol.unsupported_frame_kind`. It is a protocol violation, not a forward-compatible
  extension, because the payload cannot be skipped safely without knowing its structure
  (it *can* be skipped — the length is known — but silently ignoring it hides bugs; v1
  chooses to reject).
- Frames are decoded from a stream buffer. A partial frame is not an error; wait for more
  bytes. Decoders MUST NOT assume one `read()` equals one frame.
- Exactly one frame per write on the sender side for control messages; senders MAY batch.

## 4. Envelope

`kind = 0x01` payloads are JSON objects with this shape:

```json
{
  "v": 1,
  "id": "0f1c2b44-5f0a-4a6b-9f2e-1c8a7d3e5b11",
  "type": "clipboard.update",
  "ts": 1762800000000,
  "body": { }
}
```

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `v` | integer | yes | Envelope version. v1 peer MUST reject `v != 1` with `protocol.version_unsupported`. |
| `id` | string (UUID) | yes | Unique per message per sender. Used for deduplication and `*_ack` correlation. |
| `type` | string | yes | Dotted lowercase identifier, see §5. |
| `ts` | integer | yes | Sender wall clock, milliseconds since Unix epoch. Informational only — never used for ordering or expiry decisions. Ordering is guaranteed by the TCP stream. |
| `body` | object | no | Type-specific. Omitted (not `null`) when a message carries no payload. |

Validation a receiver MUST perform before dispatching a message:

1. Frame `kind` is `0x01` and payload ≤ 1 MiB.
2. Payload decodes as UTF-8 JSON object.
3. `v`, `id`, `type`, `ts` present and of the right type; `id` parses as a UUID.
4. `v == 1`.
5. `type` is known for the current capability set. Unknown types MUST be ignored (logged
   at debug level, no reply) — this is the forward-compatibility mechanism.
6. `body` is validated against the schema in §5 *before* any side effect occurs.

A violation of 1–4 is fatal for the connection. A violation of 5 is ignored. A violation
of 6 is answered with an `error` message and the connection stays open.

## 5. Message catalog (v1)

Types marked *implemented* are the only ones a v1 codec is required to understand at M0.
Everything else is normative for M1+ and MUST be ignored by an M0 build (unknown type rule).

### 5.1 Session

| Type | Status | Body |
| --- | --- | --- |
| `hello` | specified | `device_id`, `device_name`, `platform`, `app_version`, `protocol_version`, `capabilities`, `nonce` |
| `hello.ack` | specified | `device_id`, `device_name`, `platform`, `app_version`, `protocol_version`, `capabilities`, `nonce`, `echo_nonce` |
| `ping` | specified | `nonce` |
| `pong` | specified | `nonce` |
| `error` | specified | `code`, `message`, `ref_id` (optional) |

`hello` MUST be the first envelope sent by both sides after the TLS handshake. The peer's
`device_id` MUST be in the trusted-device store and the presented certificate fingerprint
MUST match the pinned value, otherwise the connection is closed with `auth.denied`.

`platform` is one of `macos`, `android`.

`capabilities` is an array of strings from: `clipboard`, `clipboard.sensitive`,
`notifications`, `file-transfer`, `mirroring`, `presence`.

`nonce` is 16 random bytes, lowercase hex. `echo_nonce` in `hello.ack` MUST equal the
`nonce` from the peer's `hello`; this binds the ack to that connection and blocks
trivially replayed hellos.

### 5.2 Clipboard

| Type | Status | Body |
| --- | --- | --- |
| `clipboard.update` | specified (M2) | `content_type`, `text`, `hash`, `change_count`, `origin_id`, `sensitive` |
| `clipboard.ack` | specified (M2) | `ref_id`, `accepted`, `reason` (optional) |

- `content_type` is `text/plain` in v1.
- `hash` is lowercase hex SHA-256 of the UTF-8 `text`, used for loop suppression.
- `origin_id` is the device that first produced the content. A device MUST NOT echo an
  update back to its `origin_id`, and MUST NOT emit a new update when it applies inbound
  content (that is what prevents infinite loops).
- `change_count` is the sender's local monotonic counter, used to reject stale updates
  arriving on a re-established session.
- `sensitive` reflects `ClipDescription.EXTRA_IS_SENSITIVE` on Android. Sensitive content
  is never written to disk, never stored in history, and surfaced to the macOS pasteboard
  only when the user has enabled sensitive-content sync.
- Clipboard text is capped at 256 KiB. Larger content is dropped client-side with
  `clipboard.ack { accepted: false, reason: "too_large" }`; it is never truncated silently.

### 5.3 Notifications (M5)

| Type | Status | Body |
| --- | --- | --- |
| `notification.post` | specified (M5) | `key`, `package`, `app_name`, `title`, `text`, `posted_at`, `sensitive` |

`key` is `"<package>:<id>:<postTime>"`. Receivers MUST deduplicate on `key` for at least
5 minutes to avoid duplicate macOS banners on reconnect.

### 5.4 Pairing

| Type | Status | Body |
| --- | --- | --- |
| `pair.request` | specified (M1) | `device_id`, `device_name`, `platform`, `fingerprint`, `nonce`, `protocol_version`, `capabilities` |
| `pair.confirm` | specified (M1) | `fingerprint`, `nonce`, `sas_digest` |
| `pair.result` | specified (M1) | `accepted`, `reason` (optional) |

Pairing runs on a *separate*, short-lived TLS session that is allowed to proceed with an
unpinned certificate, and only while a pairing window is open (60 s, one connection at a
time, at most 3 attempts). See §7.

Field details:

- `fingerprint` is lowercase hex SHA-256 of the DER-encoded SubjectPublicKeyInfo (SPKI) of
the sender's certificate — 64 hex characters. The SPKI, not the whole certificate, so a
re-issued certificate for the same key is still recognised as the same device.
- `nonce` is 16 fresh random bytes as 32 lowercase hex characters, generated per connection.
- `sas_digest` is lowercase hex SHA-256 of the SAS input defined in §7.
- `reason` on `pair.result` is one of `user_rejected`, `sas_mismatch`, `window_closed`,
  `rate_limited`, `already_paired`, `internal`. It is informational; both sides treat any
  non-accepted result as a failed pairing.

A peer MUST NOT send `pair.*` on a normal session. Receiving one on an authenticated
session is a protocol violation (`protocol.malformed`) and closes the connection: it is
either a bug or an attempt to re-pair without user consent.

### 5.5 File transfer (M5)

Implemented for local-network transfers using JSON envelope frames (`kind = 0x01`):

| Type | Status | Body |
| --- | --- | --- |
| `file.offer` | specified (M5) | `transfer_id`, `filename`, `size_bytes`, `sha256`, `mime_type` |
| `file.accept` | specified (M5) | `transfer_id` |
| `file.reject` | specified (M5) | `transfer_id`, `reason` |
| `file.chunk` | specified (M5) | `transfer_id`, `offset`, `data_b64` |
| `file.complete` | specified (M5) | `transfer_id`, `sha256` |

- `transfer_id` is a lowercase UUID string uniquely identifying the transfer.
- `filename` is sanitized (base name only, max 255 bytes; path traversal components rejected).
- `size_bytes` is the total file size in bytes (integer >= 0).
- `sha256` is the lowercase hex SHA-256 of the complete file content, used for integrity verification upon completion.
- `data_b64` is standard Base64-encoded chunk payload. Each chunk payload MUST NOT exceed 512 KiB raw (so the JSON envelope remains strictly under the 1 MiB frame limit).
- Receivers write chunks incrementally or to a temporary file, verify total size and SHA-256 on `file.complete`, resolve filename conflicts (e.g., appending ` (1)`), and move to the configured destination (`~/Downloads` on macOS, `Downloads/Klyndro` on Android).
- A receiver rejects an offer with `file.reject` and a `reason` instead of accepting it. Reasons used: `busy`, `too-large` (above 2 GiB), `invalid-size`, `invalid-hash`, `storage-unavailable`. Chunks must arrive in order and stay within the offered size; otherwise the receiver abandons the transfer and discards the partial file.
- Binary `kind = 0x02` chunk frames remain reserved for a future v2 throughput optimization.

## 6. Error codes

| Code | Meaning | Connection |
| --- | --- | --- |
| `protocol.version_unsupported` | Envelope `v` is not 1 | close |
| `protocol.malformed` | Unparseable frame/envelope or missing required field | close |
| `protocol.frame_too_large` | Frame length outside `[1, 1048576]` | close |
| `protocol.unsupported_frame_kind` | Unknown frame kind byte | close |
| `protocol.unknown_type` | Informational; unknown message type received | stays open |
| `auth.denied` | Peer unknown, fingerprint mismatch, or pairing not confirmed | close |
| `auth.replay` | Nonce/`echo_nonce` mismatch | close |
| `pairing.window_closed` | `pair.*` received with no open pairing window | close |
| `pairing.rejected` | User declined the code on either device | close |
| `pairing.sas_mismatch` | Confirmation digest disagreed | close |
| `pairing.rate_limited` | More than 3 attempts in one window | close |
| `payload.too_large` | Valid envelope, payload over the type's limit | stays open |
| `busy` | Too many sessions | close |
| `internal` | Unexpected local failure | stays open |

Error `message` strings are for humans, are never used for control flow, and MUST NOT
contain clipboard content, notification text, or key material.

## 7. Pairing (SAS)

Goal: two devices that have never met establish mutual trust, with a human confirming
that no one is in the middle.

1. **Discovery.** The Android device advertises `_klyndro._tcp` with TXT keys
   `id`, `name`, `proto`, `fp` (base64url SPKI SHA-256), `caps`. macOS browses. Manual
   IP entry skips discovery but not pairing.
2. **Pairing window.** The user clicks *Pair* on macOS. macOS opens a 60-second pairing
   window and accepts exactly one connection on the pairing listener.
3. **Handshake.** TLS is established but the peer certificate is *not* pinned yet. Each
   side sends `pair.request` containing its own fingerprint and a fresh 16-byte `nonce`.
4. **SAS derivation.** Both sides compute, over the same byte string:

   ```text
   pair_i  = fp_i (lowercase hex ASCII, 64 bytes) || nonce_i (lowercase hex ASCII, 32 bytes)
   ordered = the two pair strings sorted lexicographically by fp_i
   input   = "klyndro-sas-v1" || ordered[0] || ordered[1]
   digest  = SHA-256(input)                                  // 32 bytes
   value   = (digest[0] << 24 | digest[1] << 16 | digest[2] << 8 | digest[3]) % 1_000_000
   SAS     = value formatted as 6 decimal digits, zero padded
   ```

   Sorting by fingerprint (not by platform or role) makes the ordering independent of which
device initiated, so both sides hash identical bytes. The four-byte reduction is used rather
than a 20-bit one because 20 bits modulo 1 000 000 would make about 4.6 % of codes twice as
likely; four bytes keep the distribution uniform to within 0.0002 %.

   `sas_digest` sent in `pair.confirm` is the 32-byte `digest` in lowercase hex (64 chars).
   Comparing the full digest, not the six digits, is what detects a mismatch caused by a
   tampered fingerprint or nonce: two different inputs that happen to agree on six digits
   are still rejected.
5. **Human confirmation.** Both devices display the same six digits. The user confirms on
   *both* devices within the window. A man-in-the-middle produces different fingerprints on
   each side and therefore different SAS values, which the user will see.
6. **Commit.** Each side sends `pair.confirm` with its `fingerprint`, `nonce` and
   `sas_digest`; each verifies the peer's values match its own computation. Any mismatch
   aborts the window.
7. **Persist.** On success both sides store `{device_id, device_name, fingerprint,
   last_known_address, paired_at}` — macOS in the Keychain, Android in
   Keystore-encrypted storage. This record is the sole basis for future automatic trust.
8. **Reconnect.** No SAS. Mutual TLS + pinned fingerprint + `hello`/`hello.ack` with nonce
   echo.

Threat notes:

- Six decimal digits (about 20 bits) of SAS is a *human-verified* value, not a secret. An
  attacker must actively MITM
  and hope the user confirms mismatched digits. A random collision across six decimal digits
  is 1 in 1 000 000 per attempt, and attempts are limited to 3 per 60 s window. The full
  digest comparison in step 6 means a collision on the digits alone is not enough: the
  fingerprints and nonces must also agree.
- Pairing attempts are rate limited: 3 failed attempts close the window for 60 s.
- The pairing window accepts one connection at a time and closes on success or timeout.
- Nothing in pairing requires an internet connection or an account.

## 8. Discovery (mDNS)

| Property | Value |
| --- | --- |
| Service type | `_klyndro._tcp` |
| Domain | `local.` |
| Default port | 47823 |

TXT records:

| Key | Required | Value |
| --- | --- | --- |
| `id` | yes | Stable device ID (16 lowercase hex chars, random at first run) |
| `name` | yes | Human-readable device name, ≤ 63 bytes UTF-8 |
| `proto` | yes | `1` |
| `fp` | yes | base64url(SPKI SHA-256) of the device certificate |
| `caps` | no | Comma-separated capability list |

`fp` is a *stable identifier*, not a secret; it lets the macOS app recognise known
devices before connecting. Trust is still established by the TLS handshake.

Both apps MUST tolerate: duplicate advertisements from the same device, records changing
address, stale records after sleep, and devices that disappear without a goodbye packet.

## 9. Versioning and evolution

- Additive change (new message type, new optional body field): no version bump. Old peers
  ignore unknown types and unknown fields.
- Breaking change (framing, envelope, semantics of an existing type): new envelope `v`.
  v1 peers reject `v != 1` rather than attempting downgrade.

## 10. Limits

| Limit | Value |
| --- | --- |
| Max frame | 1 048 576 bytes |
| Max envelope JSON | 1 048 576 bytes |
| Max clipboard text | 262 144 bytes |
| Max notification title | 1 024 bytes |
| Max notification text | 8 192 bytes |
| Max device name | 256 bytes |
| Max concurrent sessions | 4 |
| Heartbeat interval / dead peer | 15 s / 45 s |

## 11. Logging and privacy

Never logged, at any level: clipboard text, notification title or text, pairing digits,
private keys, TLS session secrets. Safe to log: message type, envelope `id`, byte counts,
peer device ID, fingerprint (public), state transitions, error codes.
