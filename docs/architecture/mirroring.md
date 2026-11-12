# Screen mirroring

**Status: USB and Wireless mirroring implemented and verified on a Redmi Note 13 5G (M3).**
Screen-off mode verified on hardware by the user; fullscreen is NOT VERIFIED; see the table at the
end. Checked against **scrcpy 5.0.1** and `adb` 1.0.41 (platform-tools 36.0.2).

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

## Implementation map

| Piece | Where | Notes |
| --- | --- | --- |
| `adb devices -l` parser | `KlyndroKit/Mirroring/AdbDevices.swift` | Pure; `device`, `unauthorized`, `offline`, other states each carry a user message |
| Argument builder | `KlyndroKit/Mirroring/MirroringOptions.swift` | Returns an `[String]` and an `ADB=` environment; out-of-range numbers are dropped |
| Child process + state machine | `KlyndroKit/Mirroring/MirroringSession.swift` | State from `terminationHandler`, 200-line stderr ring, SIGTERM then SIGKILL after 5 s |
| UI controller | `Klyndro/AppModel+Mirroring.swift` | Why Start is unavailable is always a sentence, never a disabled button with no reason |
| Controls | `Views/MirroringSection.swift`, menu bar item | Device picker, view-only, screen-off, max size, FPS |
| Scripted trigger | `klyndro://mirror/start`, `klyndro://mirror/stop` | Same pattern as `klyndro://pair`; used for the device checks below |

Quitting the app calls `shutDown()`, which stops the child. Before M3 `shutDown()` existed but
nothing called it.

## Wireless without a cable

After a one-time `adb pair` (the "First time? Pair…" form, or `adb pair` in a terminal), Klyndro
connects over Wi-Fi by itself: on launch, and when a paired phone connects, it browses
`_adb-tls-connect._tcp`, resolves the phone's current port, and runs `adb connect`. The port changes
every time Wireless debugging is toggled, which is why it is read from Bonjour and never typed.
`_adb-tls-connect._tcp` is declared in `Info.plist` for that browse.

- When no usable phone is found (USB or Wi-Fi), Start shows a popup saying what to switch on:
  Wireless debugging for Wi-Fi, or USB debugging with the cable. If adb sees the phone but it is
  `unauthorized` or `offline`, the popup gives that specific fix instead
  (`KlyndroKit/Mirroring/MirroringGuidance.swift`, unit-tested).
- Klyndro does **not** turn Wireless debugging on for the user. Doing so needs
  `WRITE_SECURE_SETTINGS`, a sensitive permission that can only be granted through adb; it was
  considered and left out.
- Needs Wireless debugging **on** at the phone. Android may switch it off when the phone leaves
  the Wi-Fi network.
- It cannot reach a phone that never approved this Mac's adb key. Pairing stays a user action.
- An `adb` server left running by a terminal or IDE can fail LAN connects with `No route to host`
  while the same command works through Klyndro. Klyndro restarts the adb server once on that error.
  This affects any other tool using the same server; devices stay authorised.
- The pairing code is passed to `adb pair` as an argument, so other processes of the same user can
  see it for a few seconds. It is single-use and is never logged or stored.

## Known limits

- **adb serial is not a Klyndro device ID.** Nothing ties the device chosen for mirroring to a
  phone paired with Klyndro, so any authorized adb device can be mirrored. The picker shows
  every adb device; the requirement to scope ADB to trusted devices is **not met** yet. The
  honest way to close it is matching on a value the phone reports over the authenticated Klyndro
  session, which needs a protocol field and is future work.
- **Wireless debugging is not enabled by Klyndro.** `adb tcpip` opens a debug port on the Wi-Fi
  network until reboot or USB reconnect. That is a security-relevant change and must be an
  explicit user action, so the UI does not do it silently.
- scrcpy's modifier is left Alt or left Super. `MOD+Left` rotates, `F11` toggles fullscreen.

## Verification results

Device: Redmi Note 13 5G, HyperOS 3, Android 15, USB. Control and window checks drove the real
scrcpy window with synthesized mouse and key events.

| Test | Status |
| --- | --- |
| Detect adb and scrcpy, display versions | **PASS** (unit tests + diagnostics UI) |
| Parse `adb devices -l`, all states | **PASS** (5 unit tests) |
| Argument builder, incl. hostile serial/title cannot add flags | **PASS** (5 unit tests) |
| Process state machine: run, stop, quick failure, clean exit, double start, SIGTERM ignored then killed | **PASS** (6 tests against fake scripts) |
| Start mirroring over USB from the app (`klyndro://mirror/start`) | **PASS** — scrcpy's parent is Klyndro, window titled `Klyndro — 2312DRAABG`, 440x1010 |
| Mouse control | **PASS** — a click in the window switched the phone's tab from Permissions to Devices |
| Keyboard control | **PASS** — typing `hi` in the window arrived in a phone text field |
| Rotate | **PASS** — `Alt+Left` changed the window from 440x1010 to 977x472; `Alt+Right` returned it |
| Resize | **PASS** — dragging a corner changed the window from 438x1005 to 461x1056, aspect kept |
| Stop from the app leaves no process | **PASS** — 0 scrcpy and 0 scrcpy-server processes |
| Quit the app while mirroring leaves no process | **PASS** — 0 scrcpy and 0 scrcpy-server processes after the app exited |
| adb lost while mirroring (`adb kill-server`) | **PASS for process cleanup** — scrcpy exited and Klyndro stayed alive. The failure message shown in the UI was **NOT TESTED** |
| Fullscreen (`F11`) | **NOT VERIFIED** — the window moved and changed z-order but kept its size; not enough to claim fullscreen |
| Screen-off mode (`--turn-screen-off`) | **PASS** — verified dark panel on device by user inspection |
| Wireless mirroring over Wi-Fi (`adb connect` target) | **PASS** — launched via Klyndro child process (`192.168.21.92:43729`), mouse click in window successfully switched phone tab |
| Automatic Wi-Fi connect (no USB): app finds the phone via `_adb-tls-connect._tcp` and runs `adb connect` | **PASS** — app started with no adb server and no cable; `adb devices` listed `192.168.66.63:37171` within 35 s. Tested only on a phone already paired with this Mac's adb |
| Wi-Fi connect when a foreign adb server (started from a terminal) is running | **PASS** — failed with `No route to host`; after `adb kill-server` the app-started server connected. The app now restarts the server once on that error. The restart-on-error path itself was **NOT TESTED** end to end |
| Popup when no phone is usable (Wi-Fi: Wireless debugging, USB: USB debugging) | **PASS** — logic by 3 unit tests; popup and the Wi-Fi start flow confirmed on screen by the user (manual, not scripted) |
| Wireless mirroring (`--tcpip`) | **NOT TESTED** — requires running `adb tcpip` which opens port 5555; avoided in favour of Android 11+ Wireless Debugging |
| First-time wireless pairing (`adb pair`) from the app form | **NOT TESTED** — the phone was already paired. A terminal `adb pair` failed twice with `protocol fault` for an unestablished reason |
| Restart after network drop | **NOT TESTED** — there is no auto-restart |
| UI text for `unauthorized` / missing scrcpy | **NOT TESTED** on screen; the strings are unit-tested |
