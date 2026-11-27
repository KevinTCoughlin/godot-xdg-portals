# Compatibility

## Engine

| Godot | Status |
| --- | --- |
| 4.4.x | Supported. 4.4.1 is the compatibility floor and a required CI version. The native library is built with godot-cpp `godot-4.4.1-stable`. |
| 4.5–4.6 | Expected to work. `compatibility_minimum` is `4.4`. These versions are not in CI. |
| 4.7.2 | Production pin. Required CI lane: mock suite, native smoke test, and the sanitizer smoke. |
| 4.8-beta5 | Opt-in preview. The workflow `Godot 4.8 preview` runs the mock suite and the native smoke test. Start it from the Actions tab, or add the `ci:godot-preview` label to a pull request. A failure does not fail the required checks. Not a supported target. |
| 4.3 and older | Unsupported. The GDExtension ABI level declared here is 4.4. |

godot-cpp is pinned to `godot-4.4.1-stable`, preserving the 4.4 minimum
(`compatibility_minimum = "4.4"` in `xdg_portals.gdextension`; there is no
`compatibility_maximum`). The bundled `extension_api.json` is the 4.4.1 API.
CI loads that same native library in Godot 4.4.1 and 4.7.2. The opt-in
4.8-beta5 workflow loads it too. It does not rebuild against the 4.8
`extension_api.json`: a library built for a newer API would not load in 4.4
or 4.7.

This repository does not compile the Godot engine, and it does not build
godot-cpp with SCons. `scripts/build.sh` fetches the pinned tag and builds it
with CMake. That tag's binding generator requires Python 3.4 or newer
(`find_package(Python3 3.4)`). Godot 4.8-beta2 raised the *engine* SCons/CI
Python floor from 3.9 to 3.10; that floor does not apply here. The
ubuntu-24.04 runners provide Python 3.12.

## Platforms

| Platform | Backend | Notes |
| --- | --- | --- |
| Linux x86-64 | native | Prebuilt archive on the [releases page](https://github.com/KevinTCoughlin/godot-xdg-portals/releases) since 0.2.0. |
| Linux arm64 | native | Prebuilt archive on the [releases page](https://github.com/KevinTCoughlin/godot-xdg-portals/releases) since 0.2.0, built on an ARM64 runner. |
| Linux, no session bus | null | Headless servers, containers, `--headless` CI. Reports GLib's own reason. |
| Windows | null | No portal service exists, and no native equivalent is built. |
| macOS | partial (`macos`) | Power-saver state only, via `MacPowerMonitor`. Universal (x86-64 + arm64); prebuilt in the `-asset-store.zip` release archive since 0.2.1. The other four report unavailable. |
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
| `GameMode` | yes | yes | yes | Provided by `xdg-desktop-portal` itself, forwarding to host `gamemoded`. Without `gamemoded`, `request_game_mode()` fails and `query_game_mode()` reports unknown. |
| `Inhibit` | yes | yes | partial | wlroots backends implement idle inhibition; logout and user-switch bits may be ignored. |
| `PowerProfileMonitor` | yes | yes | yes | Backed by `power-profiles-daemon` or `tuned`; reports unknown when neither runs. |
| `OpenURI` | yes | yes | yes | `SchemeSupported` needs `xdg-desktop-portal` 1.16+. |
| `Notification` | yes | yes | yes | Action delivery requires the app to be running. |

This table reflects the interfaces the addon uses, not the full portal surface.
Because everything is discovered at runtime, a desktop that gains or loses an
implementation needs no change here. The native backend notices a restart by
itself: requests the old instance never answered, and inhibitions it had
already granted, complete with `Response.OTHER`; signal subscriptions follow
the new instance; the power-saver state is re-read; and the facade refreshes
capabilities when the new instance appears, and drops them while the name is
unowned so calls do not block on it. `refresh_capabilities()` still
forces that read. A GameMode registration survives the restart — it is held by
`gamemoded` for the game process — and is not registered again.

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
