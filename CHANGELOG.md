# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Before 1.0 the public API may change in a minor release.

## [Unreleased]

### Added

- **Experimental macOS backend**, covering power-saver state only. A
  `MacPowerMonitor` GDExtension class reads `-[NSProcessInfo
  isLowPowerModeEnabled]` and forwards
  `NSProcessInfoPowerStateDidChangeNotification`, surfaced through the existing
  `is_power_saver_enabled()` and `power_saver_changed`. The other four
  capabilities report unavailable, as they do on any null-backend platform.
  Libraries are universal (x86-64 + arm64) and are not yet prebuilt in the
  release archive. Verified only as far as CI can: it builds, is universal,
  exports its entry point and links Foundation. The behaviour itself is a manual
  checklist in `docs/native-testing.md` and has not been run on hardware.

- `DesktopServices.get_supported_inhibit_flags()` and the matching backend method,
  reporting which `InhibitFlags` bits the current backend can request. Against a
  portal this is every documented bit; a backend that cannot inhibit reports
  `0`. It declares what is requestable, not what a session honoured — the portal
  never reports which bits it acted on — and it does not gate `inhibit()`.

### Fixed

- The test runner now fails a suite that contributes no test methods. Godot's
  `load()` returns a script that failed to compile rather than `null`, so a
  syntax error in a suite previously read as a green run with that suite
  silently absent — which is how a broken `test_power_profile.gd` passed
  locally during this change.

### Changed

- **Breaking (backend authors only): the backend contract reports capabilities
  directly.** `get_interface_versions() -> Dictionary` (keyed by
  `org.freedesktop.portal.*` names) is replaced by two methods:
  `get_capabilities()`, keyed by `Capability`, which decides availability and
  which every backend can answer; and `get_interface_version(capability)`, the
  portal interface version, `-1` on any backend that is not a portal.

  Nothing changes for game code — `has_capability()` and
  `get_interface_version()` keep their signatures and meanings. What changes is
  that a non-portal backend no longer has to answer in a vocabulary describing
  D-Bus interfaces it does not have: the macOS backend now reports
  `POWER_PROFILE_MONITOR` and nothing else, instead of a table of portal names
  with one entry set. Custom backends implementing the old method must migrate.

  `INTERFACE_NAMES` remains, documented as descriptive rather than the
  mechanism; `get_interface_version(c) >= 0` is no longer an availability check.

- **Breaking: the autoload is now `DesktopServices`, not `XDGPortal`.** With a
  macOS backend in the tree, a name asserting XDG portals was no longer honest —
  the facade fronts whatever the platform can back. The backend contract and its
  implementations are renamed to match (`DesktopServicesBackend`,
  `DesktopServicesNullBackend`, `DesktopServicesMockBackend`,
  `DesktopServicesNativeBackend`, `DesktopServicesMacBackend`), and the facade
  script moves to `addons/xdg_portals/desktop_services.gd`.

  Migration is a rename: `XDGPortal.` → `DesktopServices.` at every call site.
  No method, signal, enum or return contract changed. Projects that enable the
  plugin get the new autoload registered automatically; projects that pinned the
  autoload in `project.godot` by hand must update that line.

  The addon folder, the `xdg_portals` plugin and the native library keep their
  names: on Linux the extension genuinely is the portal bridge. Permitted
  pre-1.0, per the versioning note above.

## [0.1.0] — 2026-09-06

Initial release.

### Added

- `XDGPortal` autoload: a typed GDScript facade over selected XDG Desktop Portal
  interfaces, installed by the `xdg_portals` editor plugin.
- `org.freedesktop.portal.GameMode` support — `QueryStatus`, `RegisterGame` and
  `UnregisterGame`, exposed as `query_game_mode()`, `request_game_mode()` and
  `release_game_mode()`.
- `org.freedesktop.portal.Inhibit` support — `Inhibit()` with typed flags, and
  handle closing through `org.freedesktop.portal.Request.Close`.
- `org.freedesktop.portal.PowerProfileMonitor` support — the
  `power-saver-enabled` property and its change notifications, surfaced as
  `is_power_saver_enabled()` and the `power_saver_changed` signal.
- `org.freedesktop.portal.OpenURI` support — `OpenURI()`, plus `SchemeSupported`
  gated on interface version 5.
- `org.freedesktop.portal.Notification` support — `AddNotification`,
  `RemoveNotification`, and forwarding of `ActionInvoked`.
- `XdgPortalNative` GDExtension: C++17 over GLib/GIO with a private
  `GDBusConnection` on a private `GMainContext` driven by one worker thread. No
  process is ever spawned; `dbus-send`, `gdbus` and `busctl` are not used.
- Injectable backends: `XDGPortalNativeBackend`, `XDGPortalNullBackend` and
  `XDGPortalMockBackend`, behind the `XDGPortalBackend` contract.
- Capability and interface-version discovery, with `capabilities_changed`.
- Deterministic mock-backed test suite (70 tests) and a native smoke test that
  runs the extension against a scripted fake portal on a private session bus.
- Demo project exercising every call, CMake build pinned to godot-cpp
  `godot-4.4.1-stable`, GitHub Actions for native builds, tests, script syntax
  and REUSE linting, and a tagged-release workflow producing a Linux x86-64
  addon archive.
- `XDG_PORTALS_DEBUG=1` traces bus traffic on stderr.

### Security

- `file:` URIs are rejected case-insensitively and never reach the bus.
- URI schemes are validated against RFC 3986 syntax before any call is made.
- No API path lets game code build an arbitrary D-Bus message: `GVariant`
  conversion is one-way (bus → Godot), and notification payloads are assembled
  from a fixed set of fields.
- Flatpak needs only `--socket=session-bus` and
  `--talk-name=org.freedesktop.portal.Desktop`; no wildcard `--talk-name` and no
  system bus access.

[Unreleased]: https://github.com/KevinTCoughlin/godot-xdg-portals/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/KevinTCoughlin/godot-xdg-portals/releases/tag/v0.1.0
