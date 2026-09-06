// SPDX-FileCopyrightText: 2026 Kevin Coughlin
//
// SPDX-License-Identifier: MIT

#ifndef XDG_PORTALS_PORTAL_CONSTANTS_H
#define XDG_PORTALS_PORTAL_CONSTANTS_H

namespace xdg_portals {

// The well-known bus name and object path every desktop portal interface is
// exported on. See https://flatpak.github.io/xdg-desktop-portal/docs/
inline constexpr const char *PORTAL_BUS_NAME = "org.freedesktop.portal.Desktop";
inline constexpr const char *PORTAL_OBJECT_PATH = "/org/freedesktop/portal/desktop";

inline constexpr const char *IFACE_PROPERTIES = "org.freedesktop.DBus.Properties";
inline constexpr const char *IFACE_REQUEST = "org.freedesktop.portal.Request";
inline constexpr const char *IFACE_GAME_MODE = "org.freedesktop.portal.GameMode";
inline constexpr const char *IFACE_INHIBIT = "org.freedesktop.portal.Inhibit";
inline constexpr const char *IFACE_POWER_PROFILE_MONITOR = "org.freedesktop.portal.PowerProfileMonitor";
inline constexpr const char *IFACE_OPEN_URI = "org.freedesktop.portal.OpenURI";
inline constexpr const char *IFACE_NOTIFICATION = "org.freedesktop.portal.Notification";

inline constexpr const char *PROP_POWER_SAVER_ENABLED = "power-saver-enabled";

// Every non-interactive call is issued synchronously with this bounded timeout
// so a wedged portal service can never stall a game frame indefinitely.
inline constexpr int SYNC_CALL_TIMEOUT_MS = 2000;

// Bus connection setup is allowed slightly longer: on a cold Flatpak start the
// portal service may still be activating.
inline constexpr int CONNECT_TIMEOUT_MS = 5000;

// org.freedesktop.portal.OpenURI.SchemeSupported was added in interface
// version 5.
inline constexpr int OPEN_URI_SCHEME_SUPPORTED_MIN_VERSION = 5;

} // namespace xdg_portals

#endif // XDG_PORTALS_PORTAL_CONSTANTS_H
