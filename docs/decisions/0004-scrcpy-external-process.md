# 0004 — Use scrcpy as an external process, not an embedded engine

Status: Accepted (M0)

## Context

Screen mirroring requires device-side encoding, a low-latency transport, input injection,
and a decoder. `scrcpy` solves all of it, is Apache 2.0, and is actively maintained. The
question was whether Klyndro should embed it.

## Decision

Launch and manage the user's own `scrcpy` binary as a child process. Do not vendor, link,
patch, or re-implement its protocol. Mirroring runs in scrcpy's own window.

## Consequences

- No maintenance of an Android video encoder or input injector, and no fork of a fast-moving
  upstream.
- No stable embedding API exists (verified against scrcpy 5.0.1), so "embedded inside the
  Klyndro window" is off the table for M3. If it is ever required, that is a new ADR with a
  different distribution model.
- The user must install `adb` and `scrcpy`; Klyndro reports them in Diagnostics rather than
  installing them silently.
- GUI-launched apps inherit a minimal `PATH`, so Klyndro resolves absolute paths and passes
  `ADB=` to the child. This is documented in `mirroring.md` because it is the first thing
  that breaks.
- Process lifecycle is ours: no orphans on quit, bounded log capture, explicit state.
- Apache 2.0 obligations stay with scrcpy and its distributors; Klyndro only launches it.
