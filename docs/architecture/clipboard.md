# Clipboard design and Android restrictions

Clipboard sync is the highest-value feature (F02) and the one most constrained by the
platform. This document records what Android actually permits, what Klyndro plans to do,
and what remains unverified.

**Status: implemented on both platforms (M2) and verified on a Redmi Note 13 5G (HyperOS 3,
Android 15) in both directions while the Android app is on screen. Logic is also covered by the
host suites (148 Swift tests incl. a two-peer integration test; 102 Android JVM tests). Background
and screen-off behaviour, HyperOS autostart, and reconnect after sleep are NOT TESTED. See
[verification status](../testing/verification-status.md#m2--clipboard-synchronization).**

## The constraint

Android 10 (API 29) restricted clipboard access. From the official behaviour-changes page
([developer.android.com](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data)):

> Unless your app is the default input method editor (IME) or is the app that currently has
> focus, your app cannot access clipboard data on Android 10 or higher.

This applies to **reading and writing**. Consequences that are easy to get wrong:

- A **foreground service is not "focus"**. Starting an FGS does not restore clipboard access.
- An `OnPrimaryClipChangedListener` only delivers events while the app has access; it is not
  a background clipboard hook.
- `NotificationListenerService` can read notification content, not the clipboard.
- Accessibility services are powerful but are **not** a documented clipboard exemption, and
  shipping one that scrapes clipboard content would be both fragile and a Play policy risk.
- Android 12+ adds the sensitive-content flag; Android 13+ shows a clipboard preview overlay.
  Sensitive items must be treated as "do not persist, do not display".

## Candidate approaches

| # | Approach | Can read in background | Can write in background | Cost / risk | Verdict |
| --- | --- | --- | --- | --- | --- |
| 1 | `ClipboardManager` from a foreground service | No | No | None, but useless alone | Rejected as a background strategy; used when the app *is* focused |
| 2 | Default IME (Klyndro keyboard) | Yes (an IME has clipboard access) | Yes | Large UX intrusion; users must switch keyboard | **Primary candidate** for true background sync, opt-in |
| 3 | AccessibilityService | Not a documented exemption | Not documented | High privilege, Play restrictions, fragile across OEMs | Rejected for v1 |
| 4 | Shizuku / ADB-privileged helper | Unverified | Unverified | Requires wireless debugging setup; security surface | Out of scope for v1; document only |
| 5 | Trampoline activity (focus-stealing) | n/a | Likely works (app gets focus briefly) | Visible flash, steals focus, bad while typing | Fallback for Mac → Android, opt-in |
| 6 | Share sheet / Quick Settings tile ("Send to Mac") | n/a (user provides content) | n/a | One extra tap | **Guaranteed** baseline, ships first |
| 7 | Root / LSPosed | Yes | Yes | Requires root | Out of scope |

Only approaches 2, 5, and 6 are planned for implementation. Nothing else is promised.

## Tiered behaviour (M2)

What shipped versus what is still planned. Android's clipboard rules make the typed-text path the
only one that always works, so it is a first-class send path, not a testing hook.

1. **Tier A — explicit send (built).** In-app "Send clipboard to Mac" (reads the focused
   clipboard once and sends it) and "Send text to Mac instead" (a text field that calls
   `ClipboardSyncEngine.explicitOutbound`, bypassing the clipboard entirely). Both go through the
   same safety rules. A share-sheet target and a Quick Settings `TileService` are **not built**
   (deferred; they are the natural next affordances for background send).
2. **Tier B — foreground sync (built).** While the Activity is resumed *and* a session is
   CONNECTED, `KlyndroViewModel` polls the clipboard every 700 ms and applies inbound updates.
   The poll loop does no work when disconnected, so an idle Klyndro is idle. This is the path the
   acceptance criteria are judged against, and it is the one that needs on-device proof.
3. **Tier C — optional IME (not built).** A minimal keyboard for background capture remains the
   only public-API path to true background sync. Deferred until Tier B is proven on HyperOS.
4. **Mac → Android** currently relies on Tier B (focused app). The focus-stealing trampoline and
   the IME paste path are not built.

If Tier C proves unreliable on HyperOS, the limitation is documented in-app rather than
hidden, and the feature is described as "send/receive on demand".

## Loop prevention and deduplication

Loops are inevitable when two devices mirror one pasteboard. The protocol handles it
structurally rather than with timers:

- Every `clipboard.update` carries `origin_id` (the device that produced the content) and
  `hash` (SHA-256 of the text).
- A device **never** echoes an update back to its origin, and **never** emits a new update
  when applying inbound content (it sets a "remote apply in progress" flag).
- Locally observed changes are compared against the last applied `hash`; equality means
  "this is our own write coming back from the pasteboard" and is dropped.
- `change_count` (monotonic per device) rejects stale updates that arrive after a session
  restart.
- Identical text copied twice in a row is deduplicated by `hash` unless the user explicitly
  asks to resend.

Both platforms will test: ping-pong between two devices, reconnection mid-paste, and the
"sensitive item" gate.

## macOS side

- Read/write via `NSPasteboard.general` with `changeCount` as the local change signal.
- Polling is avoided: `changeCount` is checked on a timer only while a session is connected
  and clipboard sync is enabled (no session → no polling). A short interval (≈400 ms) is
  acceptable for a connected state and is stopped on disconnect.
- Only `text/plain` (UTF-8) in v1. RTF, images, and file promises are explicitly out of
  scope until text sync is proven.
- Sensitive content (from Android's `EXTRA_IS_SENSITIVE`) is not written to the macOS
  pasteboard unless the user enabled the setting, is never stored, and never appears in logs.

## Size and privacy limits

| Limit | Value | Behaviour |
| --- | --- | --- |
| Clipboard text | 256 KiB | Larger content is not sent; ack with `too_large` |
| History | none in v1 | Optional history is M5 and opt-in, stored encrypted |
| Logging | none | Type, byte count, and hash prefix only — never text |

## Verification plan

Logic is proven by the unit/integration suites; the live paths still need an attached device.

| Test | Status |
| --- | --- |
| Loop suppression, dedup, echo window, own-origin, stale, sensitive gate | **PASS** — `ClipboardSyncIntegrationTests` (macOS, two peers) + `ClipboardSyncEngineTest` (Android, 14) |
| Loop suppression across reconnect (`resetSessionState`) | **PASS** — unit-tested both platforms |
| Focused clipboard write→read round trip on HyperOS | **PASS** — only from the focused Activity's UI thread; a test thread is denied (`application is not in focus`) |
| `EXTRA_IS_SENSITIVE` detection on API 33+ (HyperOS) | **PASS** — flag readable from `ClipDescription.extras` when set via a `PersistableBundle` |
| Android app in foreground: real copy in WhatsApp → macOS pasteboard | **PASS** — `Sent to Mac` 5 → 6, `pbpaste` matched |
| macOS copy → Android app in foreground | **PASS** — `Received from Mac` incremented, preview matched |
| Loop suppression on a real network | **PASS** — counters stayed flat for 14–16 s after each transfer, no echo |
| Android app backgrounded, screen off | **NOT TESTED** — expected to stop; Tier B is foreground-only by design |
| HyperOS autostart + battery exemption behaviour | **NOT TESTED** — M4 |
| Share-sheet send path / Quick Settings tile | **NOT TESTED** — not built (deferred) |
| Klyndro IME background capture (Tier C) | **NOT TESTED** — not built |
