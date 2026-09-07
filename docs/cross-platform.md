# Using this in a cross-platform game

This addon is built around Linux desktop portals, and implements only a narrow
slice elsewhere — power-saver state on macOS, nothing on Windows.
[`roadmap.md`](roadmap.md#windows-and-macos-variants) works through why. That
does not make it awkward to ship cross-platform, but it does mean the game
decides what happens where a capability is unavailable, because only the game
knows what it wants instead. This page is the pattern.

## Exporting needs no configuration

`xdg_portals.gdextension` keys its libraries by platform, so an export carries
only what matches its feature tags — the Linux portal bridge on Linux, the macOS
power monitor on macOS, and nothing at all on Windows, mobile or web. Where no
library matches, the facade's `ClassDB` lookup fails, the null backend is
selected, and every call returns an honest "unavailable".

One addon folder, no per-platform export presets, no missing-library error, and
nothing to strip before shipping.

## Branch on capability, never on platform

```gdscript
# Wrong: three other cases fail exactly the same way.
if OS.get_name() == "Linux":
    XDGPortal.inhibit(flags, "Cutscene")

# Right.
if XDGPortal.has_capability(XDGPortal.Capability.INHIBIT):
    XDGPortal.inhibit(flags, "Cutscene")
```

A Windows build is not the only place inhibition is missing. So is a headless
Linux server, a container with no session bus, a Flatpak without the portal
permission, and a desktop whose portal implementation does not export the
interface. `has_capability()` covers all of them; a platform check covers one
and silently mishandles the rest.

## Put the seam in your game, not in a wrapper library

Four of the five interfaces have a cross-platform answer that is not the portal,
and two of those ship in the engine already:

| Capability | Everywhere else | Notes |
| --- | --- | --- |
| `INHIBIT` | `DisplayServer.screen_set_keep_on()` | Covers *display* sleep on Linux, macOS and Windows. The portal adds system suspend and logout on Linux. |
| `OPEN_URI` | `OS.shell_open()` | Already `NSWorkspace.open` / `ShellExecuteExW` / `xdg-open`. Inside Flatpak, `xdg-open` is itself a portal shim. |
| `GAME_MODE` | nothing to do | Windows and macOS decide this themselves; there is no API to ask, and nothing is lost by not asking. |
| `NOTIFICATION` | in-game UI | What most games want regardless. OS notifications from a fullscreen game are of marginal value, and native ones carry packaging requirements. |
| `POWER_PROFILE_MONITOR` | macOS: covered. Windows: **no equivalent** | The addon reads Low Power Mode natively on macOS, so this answers itself there. On Windows it is still `null` — answer that with a player-facing quality setting, which is worth having anyway. |

A single autoload in the game is enough to hold all of it:

```gdscript
# platform_services.gd — the only place the game asks "can I?"
extends Node

var _inhibit_handle: String = ""


func keep_awake(enabled: bool) -> void:
    DisplayServer.screen_set_keep_on(enabled)  # display sleep, every platform
    if enabled:
        # Adds system suspend on Linux; no-ops into the null backend elsewhere.
        var wanted := XDGPortal.InhibitFlags.IDLE | XDGPortal.InhibitFlags.SUSPEND
        if wanted & XDGPortal.get_supported_inhibit_flags() == wanted:
            _inhibit_handle = XDGPortal.inhibit(wanted, "Cutscene")
    elif not _inhibit_handle.is_empty():
        XDGPortal.close_request(_inhibit_handle)
        _inhibit_handle = ""


func open_url(url: String) -> void:
    OS.shell_open(url)


func is_power_saving() -> bool:
    var state: Variant = XDGPortal.is_power_saver_enabled()
    if state == null:
        return Settings.battery_mode  # unknown: the player's setting decides
    return state
```

Note that `keep_awake()` must release both halves. `screen_set_keep_on(false)`
does not close a portal inhibit handle, and closing the handle does not restore
the engine's keep-on state.

## Treat `null` as "ask", not as `false`

This is the whole reason the tri-state exists, and it is where a cross-platform
port most often goes wrong:

```gdscript
# Wrong: on Windows this silently means "not saving power", which is a guess.
if XDGPortal.is_power_saver_enabled():
    reduce_quality()
```

`null` means the addon could not find out — on Windows, on a headless server, or
on a Linux desktop running neither `power-profiles-daemon` nor `tuned`. On
macOS the value is always knowable, so `null` there means the read itself
failed. The correct fallback is whatever the player chose in your settings menu,
not an assumption in either direction. A game that ships a battery-saver toggle
needs no platform-specific code here at all: the addon simply drives that toggle
automatically wherever it can answer.

## What not to do

- **Do not wrap this in a compatibility shim that fakes the missing pieces.** A
  shim that reports `false` for unknown power state, or emits
  `request_completed` with `SUCCESS` for a fire-and-forget `OS.shell_open()`, has
  reintroduced exactly the fabricated success this addon exists to avoid.
- **Do not gate features on `OS.get_name()`.** See above.
- **Do not assume `inhibit()` honoured everything you asked for.**
  `get_supported_inhibit_flags()` tells you what could be *requested*; no
  platform reports what the session actually did with it. Design so that a
  partially honoured inhibit is survivable.

## See also

- [`api.md`](api.md) — every method, signal and enum
- [`compatibility.md`](compatibility.md) — which backend runs where, and why
- [`native-testing.md`](native-testing.md) — the manual checklists, including
  the macOS rows CI cannot run
- [`roadmap.md`](roadmap.md#windows-and-macos-variants) — why the non-Linux
  surface is deliberately this narrow
