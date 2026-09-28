# Desktop test results

Record each real-desktop run here before a release. Use the numbered checks in
[`native-testing.md`](native-testing.md#tier-3--the-desktop-checklist-cannot-run-in-ci)
and include the distribution, desktop and portal versions, Godot version,
Flatpak runtime when applicable, and the result of each check. `Not run` is
distinct from a failed check.

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
| GNOME Linux | 1–12, 14–15 | Not run | — |
| KDE Plasma Linux | 1–12, 14–15 | Not run | — |
| wlroots compositor Linux | 1–12, 14–15 | Not run | — |
| Flatpak on a real desktop | 13 | Not run | — |
