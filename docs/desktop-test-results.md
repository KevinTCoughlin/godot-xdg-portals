# Desktop test results

Record each real-desktop run here before a release. Use the numbered checks in
[`native-testing.md`](native-testing.md#tier-3--the-desktop-checklist-cannot-run-in-ci)
and include the distribution, desktop and portal versions, Godot version,
Flatpak runtime when applicable, and the result of each check. `Not run` is
distinct from a failed check.

## 2026-10-04 — Fedora 44 GNOME (x86-64), release 0.2.0

| Environment | Evidence | Result |
| --- | --- | --- |
| Fedora Linux 44 Workstation, GNOME, x86-64 | `XDG_CURRENT_DESKTOP=GNOME`; xdg-desktop-portal 1.22.1, xdg-desktop-portal-gnome 50.0; `gamemoded` running | Real desktop session |
| Godot | 4.7.2.stable (Fedora package), editor library built from `main` at `def5a43` | — |
| Method | Headless scripts driving the facade against the real session portal; no dialog was shown, no URI opened, no notification posted | — |

| # | Result | Evidence |
| --- | --- | --- |
| 1 | **Passed (GNOME only)** | `native` backend; all five capabilities; versions GameMode 4, Inhibit 3, PowerProfileMonitor 1, OpenURI 5, Notification 1. KDE and wlroots not run. |
| 2 | **Passed** | `ACTIVE_FOR_OTHERS` (another client held GameMode) → request `true` → `REGISTERED` → release `true` → `ACTIVE_FOR_OTHERS`. |
| 3 | Not run | `gamemoded` was not stopped. |
| 4 | **Partly passed** | Inhibit idle + suspend completed with `success`, and a new `org.gnome.SessionManager` inhibitor appeared. Waiting out the blank timeout was not done. |
| 5 | **Partly passed** | `close_request()` returned `true` and the inhibitor disappeared from `GetInhibitors`. |
| 6 | Partly passed | Read returned `false` (not `null`). Toggling power-saver mode was not done. |
| 7, 8 | Not run | Opens a browser or chooser on the desktop; needs a human. |
| 9 | **Passed** | `file:///etc/passwd` rejected locally: no handle, `portal_error` "The file: scheme is not allowed." |
| 10 | **Partly passed** | `https` → `true`, nonsense scheme → `false` on OpenURI v5. No pre-1.16 portal available for the `null` case. |
| 11, 12 | Not run | Posts a desktop notification; needs a human. |
| 13 | Not run | No Flatpak build. |
| 14 | **Passed** | Process quit while holding an idle inhibition; its `org.gnome.SessionManager` inhibitor was gone afterwards. |
| 15 | Not run on the real desktop | Restarting the user's portal service was avoided; the fake-portal `restart` smoke mode covers the behaviour in CI. |

## 2026-09-27 — Ubuntu 24.04 ARM64 under WSL

| Environment | Evidence | Result |
| --- | --- | --- |
| Ubuntu 24.04.5 ARM64, WSL | `uname -m` = `aarch64`; Godot 4.7.2 installed for native smoke testing | Available for headless build and fake-portal tests |
| Headless checks | All three ARM64 libraries built; native fake-portal smoke passed under both Godot 4.4.1 and 4.7.2, including remapped request completion and Close; Godot facade suite passed 80/80 under both versions | Passed (tiers 1 and 2 only) |
| GNOME / KDE / wlroots | `XDG_CURRENT_DESKTOP` is empty; no `gnome-shell`, `plasmashell`, `sway` or `xdg-desktop-portal` process | Checks 1–12 and 14–15: **not run** |
| Flatpak | `flatpak` is not installed and there is no real portal session | Check 13: **not run** |

WSLg exposes display variables, but it does not supply the desktop session and
portal backends required by the checklist. A private D-Bus session with the fake
portal exercises tier 2 only. No real-desktop result is inferred from that run.

## Release matrix to complete

| Environment | Checks | Status | Tester / date / evidence |
| --- | --- | --- | --- |
| GNOME Linux | 1–12, 14–15 | Partial: 1, 2, 9, 14 passed; 4, 5, 6, 10 partly; rest not run | Claude Code (headless) / 2026-10-04 / above |
| KDE Plasma Linux | 1–12, 14–15 | Not run | — |
| wlroots compositor Linux | 1–12, 14–15 | Not run | — |
| Flatpak on a real desktop | 13 | Not run | — |
