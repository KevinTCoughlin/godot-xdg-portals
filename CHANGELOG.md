# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Before 1.0 the public API may change in a minor release.

## [Unreleased]

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
