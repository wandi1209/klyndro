# Platform limitations

Constraints imposed by macOS, Android, HyperOS, and the tools Klyndro drives. Every entry
names whether it was **verified** here (with a source) or is still an assumption.

## Android

| # | Constraint | Source / evidence | Impact | Status |
| --- | --- | --- | --- | --- |
| A1 | Clipboard is readable/writable only by the focused app or the default IME | [Android 10 privacy changes](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data) | Automatic background clipboard sync is impossible for a normal app; tiers and fallbacks required | **Verified** (official docs) |
| A2 | A foreground service does not grant clipboard access | Follows from A1 (the rule names focus and IME, not FGS) | Do not build an FGS that expects clipboard access to work | **Verified** by documentation; not tested on device |
| A3 | Clipboard "sensitive" flag exists and must be honoured | `ClipDescription.EXTRA_IS_SENSITIVE` (API 33+ exposure) | Sensitive content is excluded from sync by default | **Verified** (platform API) |
| A4 | `NotificationListenerService` requires a user-granted binding in system settings | Android notification-access settings | Cannot be enabled programmatically; must be explained and degrade gracefully | **Verified** (platform API) |
| A5 | Android 14+ requires a declared foreground service type; `connectedDevice` fits a long-lived device session | Android 14 FGS type requirements | M4 service must declare the type and its permission | Not yet verified on this toolchain |
| A6 | mDNS discovery needs a multicast lock to receive responses on Wi-Fi | `WifiManager.MulticastLock` behaviour | Discovery may silently see nothing without it | Assumption to verify in M1 |
| A7 | Background execution can be killed regardless of code correctness | OS process management | Reconnection must be cheap, and the UI must show "service not running" instead of pretending | **Verified** behaviour by design |

## HyperOS / Redmi Note 13 5G

Target device: Xiaomi Redmi Note 13 5G on HyperOS 3. **No device is attached to the
development machine, so every item below is BLOCKED, not verified.**

| # | Likely behaviour | Planned handling |
| --- | --- | --- |
| H1 | Autostart is disabled by default (Security app → Autostart) | Onboarding step with exact path and a check on next launch |
| H2 | Battery saver restricts background work; "No restrictions" is required | Explain in-app; never nag more than once per session |
| H3 | Background activity launch blocked by default | Avoid trampoline activities unless the user opts in |
| H4 | Additional notification/overlay prompts may appear | Handle refusal as a supported state, not an error |
| H5 | Clipboard rules match AOSP unless Xiaomi documents otherwise | Assume AOSP rules; verify with real tests |

## macOS

| # | Constraint | Impact | Status |
| --- | --- | --- | --- |
| M1 | Local network privacy prompt is required before mDNS/browsing | First run must tolerate a refused prompt and offer manual IP entry | Assumption; verify in M1 |
| M2 | A GUI app inherits a minimal `PATH`, so Homebrew tools appear "missing" | Diagnostics probes fixed directories; scrcpy receives an absolute `ADB` path | **Verified** (this repository's `ToolchainProbe` searches explicit paths) |
| M3 | App Sandbox prevents launching arbitrary external binaries | Mirroring forces either no sandbox or bundled helpers — see ADR 0006 | **Verified** by design review; revisit at M3 |
| M4 | Launch at login requires a signed app and `SMAppService` | M6 must define signing/distribution before M4 can be called complete | Not implemented |
| M5 | Sleep/wake invalidates sockets without a clean close | Reconnect logic must not treat wake as a failure spike | Designed (M4) |

## scrcpy / adb

| # | Constraint | Impact | Status |
| --- | --- | --- | --- |
| S1 | No embeddable library or stable IPC API | scrcpy runs as a separate window (ADR 0004) | **Verified** (5.0.1 `--help`, project docs) |
| S2 | Wireless debugging on Android 11+ needs a one-time pairing step | Cannot promise zero-touch wireless mirroring | Not verified |
| S3 | adb server is a local service on port 5037 | Scope adb to paired devices; never expose it to the LAN | Designed (M3) |
| S4 | scrcpy is Apache 2.0 | Attribution; no vendoring without NOTICE handling | **Verified** |

## Deliberate non-goals

- Universal control (typing into one device from the other's keyboard) beyond what scrcpy
  provides.
- Any feature that requires root, a custom Android system image, or a private API.
- Cloud relay, account system, or telemetry — permanently out of scope, not deferred.
- Claiming clipboard sync works on Android when it only works while Klyndro is on screen.
