# Security policy

## Supported versions

| Version | Supported |
| --- | --- |
| 0.1.x | Yes |
| < 0.1 | No |

Until 1.0, only the latest minor release receives security fixes.

## Reporting a vulnerability

**Do not open a public issue.**

Report privately through GitHub's
[private vulnerability reporting](https://github.com/KevinTCoughlin/godot-xdg-portals/security/advisories/new)
for this repository. If that is unavailable to you, contact the maintainer
through their GitHub profile at <https://github.com/KevinTCoughlin>.

Please include:

- what an attacker can achieve, and what access they need to start;
- affected version, distribution, desktop environment and portal version;
- whether the target runs in a Flatpak sandbox;
- a reproduction, ideally against the demo project.

You can expect an acknowledgement within 5 working days and an assessment within
15. Fixes are released as soon as they are ready; a GitHub Security Advisory is
published with credit to the reporter unless you ask otherwise. Please give a
reasonable disclosure window — 90 days is the default — and tell us if the issue
is already public or under embargo elsewhere.

## Threat model

This addon sits between untrusted-ish game code and a privileged desktop
service, so the interesting boundary is what a game (or a mod, or a script it
loads) can make the portal do.

Design properties that are intended to hold, and are therefore worth reporting
as bugs if they do not:

- **No arbitrary D-Bus invocation.** There is no API path from GDScript to a
  bus message of the caller's choosing. `GVariant` conversion is one-way
  (bus → Godot); notification payloads are assembled from a fixed set of fields;
  bus name, object path, interface and member are compile-time constants in
  `src/portal_constants.h`.
- **No `file:` URIs.** `open_uri()` rejects the `file:` scheme
  case-insensitively before any call is made, and `is_scheme_supported("file")`
  reports `false` whatever the portal says.
- **URI schemes are validated** against RFC 3986 syntax on both the GDScript and
  native sides.
- **Inhibit flags are masked.** Only the four documented bits are accepted;
  anything else is rejected locally.
- **Bounded blocking.** Every synchronous call carries a 2-second timeout, so a
  wedged or hostile portal service cannot hang the game indefinitely.
- **Minimal sandbox permissions.** The addon needs only
  `--socket=session-bus` and `--talk-name=org.freedesktop.portal.Desktop`. A
  change that requires a broader permission is a security regression.
- **No process execution.** Nothing here spawns a process; there is no
  `dbus-send`, `gdbus` or shell invocation to inject into.

## Out of scope

- Vulnerabilities in `xdg-desktop-portal`, its backends, GLib, or the Godot
  engine — report those upstream (though tell us if this addon makes one
  reachable that would not otherwise be).
- A game deliberately calling a portal in a user-visible way. `open_uri()`
  opening a browser is the feature, not a flaw.
- Denial of service caused by a portal service that is itself unavailable; the
  addon reports that state honestly and continues.
