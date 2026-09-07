# Compatibility

## Engine

| Godot | Status |
| --- | --- |
| 4.4.x | Supported and tested (4.4.1 in CI). |
| 4.5+ | Expected to work — `compatibility_minimum` is `4.4` and the extension uses no 4.4-only API. Not covered by CI yet. |
| 4.3 and older | Unsupported. The GDExtension ABI level declared here is 4.4. |

godot-cpp is pinned to `godot-4.4.1-stable`. An extension built against 4.4
loads in later 4.x engines; the reverse is not true.

## Platforms

| Platform | Backend | Notes |
| --- | --- | --- |
| Linux x86-64 | native | Prebuilt in the release archive. |
| Linux arm64 | native | Supported by the build; not prebuilt — run `scripts/build.sh` on the target. |
| Linux, no session bus | null | Headless servers, containers, `--headless` CI. Reports GLib's own reason. |
| Windows | null | No portal service exists, and no native equivalent is built. |
| macOS | partial (`macos`) | Power-saver state only, via `MacPowerMonitor`. Universal (x86-64 + arm64); not prebuilt yet. The other four report unavailable. |
| Android / iOS | null | No portal service exists. |
| Web | null | Detected via `OS.has_feature("web")` before anything else. |

On every null-backend platform the addon still imports, the autoload still
installs, and every call returns an honest "unavailable" answer. No native
library is required, and none is loaded.

For what a game should do on those platforms instead, see
[`cross-platform.md`](cross-platform.md).

## Runtime dependencies

- GLib, GIO and GObject ≥ 2.66, linked dynamically against the host system or
  the Flatpak runtime. Every Flatpak runtime and every mainstream distribution
  from 2020 onward ships a newer version.
- `xdg-desktop-portal` and a portal backend implementation
  (`xdg-desktop-portal-gtk`, `-kde`, `-gnome`, `-wlr`, `-hyprland`, …).

## Portal interfaces

The addon reads each interface's `version` property at startup and reports the
result through `get_interface_version()`. A missing interface is `-1` and every
call against it fails honestly.

| Interface | Version used | If older | If absent |
| --- | --- | --- | --- |
| `GameMode` | 1 | — | `query_game_mode()` → `UNKNOWN`, requests → `false` |
| `Inhibit` | 1+ (3 typical) | — | `inhibit()` → `""` |
| `PowerProfileMonitor` | 1 | — | `is_power_saver_enabled()` → `null` |
| `OpenURI` | 1+; `SchemeSupported` needs 5 | `is_scheme_supported()` → `null`; `open_uri()` still works | both → `""` / `null` |
| `Notification` | 1+ (2 typical) | — | notification calls → `false` |

## Desktop support

Portal *interfaces* are provided by `xdg-desktop-portal`, but each one is
implemented by a desktop-specific backend, so availability varies:

| Interface | GNOME | KDE Plasma | wlroots (sway, Hyprland) | Notes |
| --- | --- | --- | --- | --- |
| `GameMode` | yes | yes | yes | Provided by `xdg-desktop-portal` itself, forwarding to host `gamemoded`. Returns "rejected" if `gamemoded` is not installed. |
| `Inhibit` | yes | yes | partial | wlroots backends implement idle inhibition; logout and user-switch bits may be ignored. |
| `PowerProfileMonitor` | yes | yes | yes | Backed by `power-profiles-daemon` or `tuned`; reports unknown when neither runs. |
| `OpenURI` | yes | yes | yes | `SchemeSupported` needs `xdg-desktop-portal` 1.16+. |
| `Notification` | yes | yes | yes | Action delivery requires the app to be running. |

This table reflects the interfaces the addon uses, not the full portal surface.
Because everything is discovered at runtime, a desktop that gains or loses an
implementation needs no change here — call `refresh_capabilities()` after a
portal restart.

## Flatpak

Portals are the supported sandbox escape hatch, so only the portal endpoint is
needed:

```yaml
finish-args:
  - --socket=session-bus
  - --talk-name=org.freedesktop.portal.Desktop
```

Deliberately **not** required, and not to be added on this addon's behalf:

- `--talk-name=org.freedesktop.*` — a wildcard that grants far more than portals.
- `--talk-name=com.feralinteractive.GameMode` — the portal forwards GameMode
  registration to the host; the sandbox never speaks to `gamemoded` directly.
- `--socket=system-bus` — nothing here touches the system bus.

## Architecture and packaging notes

The `.gdextension` descriptor lists the `editor` entries before the `debug`
ones. The Godot editor binary carries both the `editor` and `debug` feature
tags, and the first matching key wins — listing `linux.debug.*` first sends the
editor to a `template_debug` library that a normal build does not produce.
