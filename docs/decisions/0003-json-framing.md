# 0003 — Length-prefixed JSON envelopes over one TCP connection

Status: Accepted (M0), implemented and tested

## Context

Control messages (clipboard, notifications, errors, heartbeats) are small and structured.
Options: Protobuf/gRPC, MessagePack, CBOR, WebSocket+JSON, or a custom length-prefixed JSON
frame.

## Decision

`uint32` big-endian length + `uint8` kind + payload, with JSON envelopes inside
(`{v, id, type, ts, body}`). Maximum frame 1 MiB, enforced before allocation.

## Consequences

- No schema compiler, no codegen step, and no build-time coupling between two different
  toolchains. Fixtures are readable and reviewable.
- Debugging is trivial: a frame is a length and then text. Protocol work in M1 will be
  faster to iterate on.
- Costs: JSON is larger and slower than a binary encoding, and bodies are untyped at the
  framing layer. Neither matters for a LAN channel carrying sub-megabyte clipboard text;
  file transfer will use a separate binary frame kind (`0x02`, reserved) where it does.
- Validation is explicit rather than generated, so it must be tested — which is why M0 ships
  48 Swift and 40 Kotlin tests before any feature exists.
- If profiling later shows JSON overhead is material, a binary kind can be added without
  breaking v1 peers.
