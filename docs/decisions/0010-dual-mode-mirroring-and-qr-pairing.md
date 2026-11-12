# 0010 — Dual-mode mirroring (no-ADB Standard + ADB Advanced) and QR code pairing

Status: Proposed (post-M6)

## Context

`ADR 0004` chose external `scrcpy` + `adb` for screen mirroring in M3 so Klyndro would not have
to maintain a video encoder/decoder or input injector. That shipped cleanly and remains fast and
capable, including `--turn-screen-off`, full keyboard input, and paired-phone scoping (§5.4a).

However, requiring `adb` and `scrcpy` creates a barrier for non-developer users: they must enable
Developer Options, approve USB or Wireless Debugging, and install external CLI tools (`ADR 0006`
already keeps the Mac app unsandboxed for that reason). Users also asked for two-tier control
(Standard without ADB, Advanced with ADB) and QR code pairing so mDNS and manual IP entry are
unnecessary on normal home/office networks.

## Decision

1. **Adopt a dual-mode mirroring architecture**, amending `ADR 0004` rather than replacing `scrcpy`:
   - **Standard Mode (no ADB / no Developer Options):**
     - Android captures the screen via `MediaProjection` + `VirtualDisplay` + `MediaCodec`
       (H.264/HEVC) and injects basic touch/navigation via `AccessibilityService`
       (`dispatchGesture`, `performGlobalAction`).
     - macOS decodes video via `VideoToolbox` (`VTDecompressionSession`) and displays it inside a
       native SwiftUI window.
     - **Transport:** use Klyndro's existing local TLS 1.3 control channel (`klyndro-protocol-v1`)
       for stream negotiation and input messages, and a direct local TLS/QUIC media stream via
       platform networking (`Network.framework` / `Socket` + TLS). **Do not** embed `libwebrtc`,
       which adds a large C++ dependency and ICE/STUN/TURN machinery that Klyndro's local-only
       constraint does not use.
   - **Advanced Mode (ADB + `scrcpy`, existing):**
     - Keep `scrcpy` + `adb` (with `mirror.challenge`/`mirror.proof` scoping) as the high-capability
       mode for full keyboard shortcuts, `--turn-screen-off`, and structured ADB controls
       (Home/Back/Recents, package launch, screenshot).

2. **Add QR code pairing on top of the existing mutual TLS 1.3 + 6-digit SAS flow:**
   - macOS encodes `klyndro://pair?v=1&host=<lan_ip>&port=<port>&fp=<spki_hex>&name=<name>` into a
     QR image via `CoreImage` (`CIQRCodeGenerator`) whenever the 60-second pairing window opens.
   - Android scans it offline via platform `Camera2` + `com.google.zxing:core` (Apache 2.0, pure
     Java, no Play Services or cloud), pins the Mac's SPKI fingerprint during the TLS pairing
     handshake, and still requires human comparison of the six-digit SAS before persisting trust.

## Consequences and platform limits

- **Honest platform disclosures remain mandatory:**
  - Sideloaded Android APKs (Android 13–15 / HyperOS) require the user to enable *Allow restricted
    settings* in App Info before Android lets them toggle `AccessibilityService`.
  - Android 14+ requires a `mediaProjection` foreground service type and shows the system screen
    capture consent dialog on every session start; it cannot be persisted across runs.
  - `MediaProjection` blacks out `FLAG_SECURE` windows and cannot physically turn off the panel
    the way `scrcpy --turn-screen-off` can.
- **No silent privilege escalation:** `CAMERA` permission is requested only when the user taps
  *Scan QR code*; `AccessibilityService` and `MediaProjection` are enabled only by explicit user
  action.
- **Incremental delivery:**
  1. QR code pairing (macOS generator + Android scanner + shared URI codec).
  2. Standard Mode PoC (`MediaProjection` + `MediaCodec` → local TLS → `VideoToolbox`).
  3. Standard Mode remote control (`AccessibilityService` + protocol messages).
  4. Advanced Mode structured ADB extras (navigation buttons, app launcher, screenshot).
