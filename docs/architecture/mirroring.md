# Screen mirroring

**Status: not implemented (M3).** This is the integration plan for `scrcpy`, verified
against the copy installed on the development machine: **scrcpy 5.0.1**, `adb` 1.0.41
(platform-tools 36.0.2).

## Why scrcpy as an external process

`scrcpy` is a standalone application: a small client that pushes `scrcpy-server` to the
device over `adb`, receives an H.264/H.265 stream, decodes it with FFmpeg, and renders it in
an SDL window. It does **not** ship a stable embeddable library or a documented IPC
interface for third-party clients. Attempting to link it, vendor it, or re-implement its
device-side protocol would mean maintaining an Android video encoder, an input injection
path, and a server jar — a project of its own, and a licence and update burden.

Therefore Klyndro **manages** scrcpy: it discovers devices, picks the right serial, starts
and stops the process, records its diagnostics, and presents status. The mirroring window
belongs to scrcpy.

Consequences, stated plainly:

- No in-app embedding of the video surface in M3. A future embedded mode would require a
  different design (and probably a different licence posture).
- The user must have `adb` and `scrcpy` installed. Klyndro reports them in **Diagnostics**
  and links to `brew install scrcpy`. It does not silently install privileged tooling.
- scrcpy's window is styled by scrcpy, not by Klyndro.

## Verified command surface

These flags exist in scrcpy 5.0.1 (checked with `scrcpy --help`):

| Flag | Use in Klyndro |
| --- | --- |
| `-s, --serial=<serial>` | Select the paired device when several are attached |
| `--tcpip[=[+]ip[:port]]` | Switch a USB device to wireless ADB |
| `-m, --max-size=<value>` | Resolution cap from settings |
| `--max-fps=<value>` | Frame-rate cap from settings |
| `-S, --turn-screen-off` | Optional "screen off while mirroring" |
| `--window-title=<text>` | `Klyndro — <device name>` |
| `--no-audio` | Default: do not capture device audio in v1 |
| `-n, --no-control` | Offered for view-only mode |
| `--keyboard=…` | Keyboard input mode, if a user hits issues |

## Process management design

1. Resolve `scrcpy` and `adb` through `ToolchainProbe` (already implemented in
   `KlyndroKit/Diagnostics`). Both are resolved to absolute paths.
2. Pass `ADB=<absolute adb path>` in the child environment. This is the single most common
   breakage for GUI-launched tools: a Finder-launched app inherits
   `/usr/bin:/bin:/usr/sbin:/sbin`, so `scrcpy` cannot find `adb` even though the terminal
   can. Setting `ADB` removes the dependency on `PATH` entirely.
3. Launch with `Process` and an **argument array** — never a shell string. Device names and
   paths are untrusted input and must not be interpolated.
4. Capture `stderr` into a bounded ring buffer (last ~200 lines) for the diagnostics panel.
   scrcpy output contains serials and warnings, not clipboard content.
5. State: `idle → starting → running → stopping → idle`, plus `failed` with the last error
   lines. Stop sends `SIGTERM`; if the process is still alive after 5 s, `SIGKILL` and
   report that it did not exit cleanly.
6. Klyndro never claims the process is running because it once started it: the state comes
   from `isRunning` and `terminationHandler`.
7. Starting mirroring for a device that is not connected must fail with an actionable
   message, not a hung spinner.

## Connectivity

- **USB**: requires USB debugging authorized on the phone. `adb devices -l` lists serials;
  an `unauthorized` state gets its own message ("accept the debugging prompt on the phone").
- **Wireless**: `scrcpy --tcpip=<addr>` works when adb already knows the device or when the
  device exposes wireless debugging. On Android 11+ the *first* wireless connection requires
  the pairing dialog (`adb pair <host>:<port> <code>`), which the user must complete. Whether
  scrcpy 5.x can complete pairing without a prior `adb pair` is **NOT VERIFIED** and must be
  tested in M3 before the UI promises one-click wireless.

## Screen-off mode

`--turn-screen-off` turns the physical display off while mirroring continues, which is the
privacy-friendly default for long sessions. It is a per-session toggle, not a global default:
users may need to see the phone screen while mirroring. Turning the screen back on must
always be possible from the phone itself.

## Audio

scrcpy can forward device audio on Android 11+. Klyndro disables it in v1 (`--no-audio`):
capturing a microphone or media stream without an explicit request is surprising, and audio
adds a second permission/capability conversation. If audio is added later it will be opt-in
per session.

## Licensing

scrcpy is Apache 2.0. Klyndro does not vendor, modify, or redistribute it; it launches the
user's own installation. Klyndro's own MIT licence and the attribution section in `LICENSE`
record this. If Klyndro ever bundles scrcpy (e.g. for a one-click install), the Apache 2.0
obligations — including NOTICE propagation — become Klyndro's and must be handled explicitly.

## Verification plan (all currently BLOCKED)

| Test | Status |
| --- | --- |
| Detect adb and scrcpy, display versions | `PASS` (unit tests + diagnostics UI) |
| Start mirroring over USB | BLOCKED (no device) |
| Control the phone with Mac keyboard/mouse | BLOCKED (no device) |
| Resize / fullscreen / rotate | BLOCKED (no device) |
| Wireless ADB first-time pairing | BLOCKED (no device) |
| Screen-off mode restores correctly | BLOCKED (no device) |
| Process survives network drop and is restarted | BLOCKED (no device) |
| Clean shutdown on app quit (no orphan processes) | NOT TESTED |
