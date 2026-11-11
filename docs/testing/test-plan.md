# Test plan

Two layers: automated unit tests on the host, and manual device tests. Device tests are not
optional decoration — they are the only evidence that clipboard, discovery, and mirroring
work.

## 1. Automated tests (host)

Run with `./scripts/test-all.sh`. Both suites must pass before any milestone is reported.

### macOS — Swift Testing, `apps/macos/KlyndroKit`

| Area | Cases |
| --- | --- |
| Framing | round trip; big-endian length includes kind byte; byte-at-a-time reassembly; coalesced frames; oversized length rejected without buffering; zero length rejected; unknown kind rejected; encoder refuses oversized payload; payload exactly at the limit accepted |
| Envelope | header fields; body omitted when absent or null; body round trip; deterministic bytes; missing `type`; missing `id`; non-UUID id; non-integer timestamp; version 2 rejected; non-object JSON; invalid UTF-8; unknown type tolerated; frame round trip; oversized payload |
| Fixtures | manifest matches directory; declared outcomes; re-encode preserves meaning |
| State machine | happy path; invalid transition; failure counting and reset; clean peer close resets backoff; missed heartbeat escalates; disconnect to idle; reset from every recoverable state |
| Backoff | initial delay; doubling; cap; ±20 % jitter band; monotonicity; negative attempt; random jitter bounds |
| Diagnostics | executable lookup, missing executable, multiple search directories, version summarisation, probe report shape |

### Android — JUnit 4, `apps/android/app/src/test`

The same areas, deliberately, plus Kotlin-specific edge cases:

- length prefix with the high bit set is reported as `FrameTooLarge(4294967295)`, not wrapped
  into a negative `Int` (and therefore not mistaken for an empty frame);
- strict UTF-8 decoding (`MalformedInputException` → `MalformedEnvelope`) because Kotlin's
  default decoder silently substitutes U+FFFD;
- non-integer timestamps (`1.5`, `"soon"`) rejected.

### Cross-platform conformance

`protocol/fixtures/manifest.json` is the contract. Both suites assert:

1. the manifest lists exactly the fixtures that exist on disk;
2. each fixture produces the declared outcome (`valid`, `unknown_type`, `malformed`);
3. a decoded fixture survives re-encoding unchanged in meaning.

## 2. Host-level integration tests (M1)

These run without a phone and are the strongest evidence available today. They are part of
`./scripts/test-all.sh`.

| Test | What it proves |
| --- | --- |
| `TLSIntegrationTests` (Swift) | A real TLS 1.3 handshake over loopback with mutual certificate authentication, correct fingerprint cross-checks, and refusal of unpinned peers on both sides |
| `TlsLoopbackTest` (Kotlin/JSSE) | The same guarantees on the Android stack, including the pairing-window mode |
| `PairingRunnerTests` | Two pairing runners reach the same six digits, persist each other only after mutual confirmation, and refuse a device that claims a key it does not hold |
| SAS vector test (both) | Both apps derive the code that an independent Python implementation computes |
| Bonjour advert (manual) | The macOS app is visible via `dns-sd -B _klyndro._tcp` and resolves with the full TXT record |

## 3. Manual device tests

A Redmi Note 13 5G (HyperOS 3, Android 15) is attached. The instrumentation suite has covered
identity, on-device TLS, and NSD publishing; the rows below still need a Mac-to-phone session,
which requires the Android connection service (M2). Record results in
[verification status](verification-status.md) with the exact command or observation.

### Discovery and pairing (M1)

| # | Scenario | Expected |
| --- | --- | --- |
| D1 | Both apps on the same Wi-Fi, fresh install | Device appears in the macOS list within 5 s. *Verified at the network level: the Mac discovered and resolved the phone's advertisement. The app's own browser rendering it is still unobserved.* |
| D2 | Pair with matching codes | Both sides persist the device; reconnect is automatic |
| D3 | Pair while an attacker swaps certificates | Codes differ; user aborts |
| D4 | Pairing window left open for 90 s | Window closed; no pairing |
| D5 | Manual IP entry with multicast blocked | Connection offered, pairing still required |
| D6 | Unpair on macOS | Reconnect refused until re-paired |

### Clipboard (M2)

| # | Scenario | Expected |
| --- | --- | --- |
| C1 | Android foreground, copy → macOS | Text available for ⌘V |
| C2 | macOS copy → Android foreground | Text pasted in an Android field |
| C3 | Android backgrounded, screen on | Documented tier behaviour (share/tile/IME) |
| C4 | Android screen off | Documented tier behaviour |
| C5 | Same text copied twice | No loop, at most one update |
| C6 | Disconnect and reconnect mid-copy | No duplicate paste, no stale value |
| C7 | Sensitive item copied | Not synced unless enabled |
| C8 | 300 KiB of text | Dropped with `too_large`, no partial paste |
| C9 | HyperOS with autostart/battery exemptions applied | Behaviour recorded verbatim |

### Mirroring (M3)

| # | Scenario | Expected |
| --- | --- | --- |
| S1 | USB mirroring | Window opens, input works |
| S2 | Wireless ADB (paired via `adb pair`) | Window opens |
| S3 | Rotation, resize, fullscreen | Content follows |
| S4 | `--turn-screen-off` | Phone display off, mirroring continues |
| S5 | USB cable unplugged | Error surfaced, no orphan process |
| S6 | Quit Klyndro while mirroring | scrcpy terminated |

### Background and recovery (M4)

| # | Scenario | Expected |
| --- | --- | --- |
| B1 | Launch at login | App present in menu bar after reboot |
| B2 | Mac sleep/wake | Reconnects without user action |
| B3 | Wi-Fi drop and return | Reconnects; backoff visible if repeated |
| B4 | IP address change | Reconnects via discovery |
| B5 | Android reboot | Reconnects when the OS restarts the service |
| B6 | HyperOS kills the service | UI shows "service not running", not "connected" |

### Notifications and files (M5)

| # | Scenario | Expected |
| --- | --- | --- |
| N1 | Notification arrives | One macOS banner, no duplicates on reconnect |
| N2 | App excluded from forwarding | No banner |
| N3 | Notification access revoked | Feature disables itself, explains why |
| F1 | 1 GiB file Android → Mac | Completes, hash matches |
| F2 | Transfer cancelled midway | Partial file removed |
| F3 | Filename conflict | Suffix applied, nothing overwritten |

## 4. How to record results

Use exactly one of `PASS`, `FAIL`, `BLOCKED`, `NOT TESTED` (see `AGENTS.md`). A `PASS`
requires the command or the observation, e.g.:

```text
C1 | PASS | `adb shell input ...` then ⌘V in TextEdit produced "klyndro test" | 2026-11-20
```

A `FAIL` requires the failure text. "It seemed to work" is `NOT TESTED`.

For M1 specifically, the open device questions are: does the Android NSD advertisement appear
to the Mac, do both devices show the same digits, and does revoking trust actually block a
reconnect. None of these can be answered without hardware.
