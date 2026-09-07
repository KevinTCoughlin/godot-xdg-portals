# Native testing

There are three tiers of testing here, and they are kept separate on purpose:
what CI proves, what CI proves *about the native code*, and what only a human on
a real desktop can prove.

## Tier 1 — the mock-backed suite (runs in CI)

```bash
./scripts/run_tests.sh
```

70 tests across seven suites, all through `DesktopServicesMockBackend`. No bus, no
display, no portal service, no timers — the same result on a laptop and on a
bare runner. This covers the facade: validation, capability gating, enum
mapping, signal forwarding, and the honesty rules (`null` / `-1` / `""` / `false`
for anything unknown or unavailable).

It proves nothing about the native code, by design.

## Tier 2 — the native smoke test (runs in CI)

```bash
./scripts/build.sh --target editor
./scripts/run_native_smoke.sh
```

This builds the fixture in `tests/native/fake_portal.c` — a scripted stand-in for
`org.freedesktop.portal.Desktop` written against GIO — starts it on a private
session bus via `dbus-run-session`, and runs `tests/native/native_smoke.gd`
against the **real** `XdgPortalNative` extension.

It exercises the parts of the native layer that need no human:

- connecting to a session bus and reading interface versions;
- GameMode's three synchronous calls;
- `SchemeSupported`, and local rejection of `file:` in both cases;
- `AddNotification` / `RemoveNotification`;
- request-handle prediction — the fixture rebuilds the path from the caller's
  unique name and `handle_token`, so a mismatch fails the test;
- `Request.Response` delivery for both `Inhibit` and `OpenURI`, including that a
  non-zero response code is forwarded as `CANCELLED` rather than assumed
  successful;
- `Notification.ActionInvoked` delivery and payload conversion;
- `PropertiesChanged` on `power-saver-enabled`, and that the cached state
  follows it.

This tier is the regression test for the threading bug described in
[`architecture.md`](architecture.md#threading): before it existed, every
asynchronous path failed silently — the calls went out, the portal answered, and
nothing ever came back — because the GLib calls that capture a thread-default
context were made on Godot's main thread. Nothing in tier 1 could have caught
that.

What it does **not** prove: that a real portal implementation behaves the way the
fixture does.

## Tier 3 — the desktop checklist (cannot run in CI)

These checks need a graphical Linux session with a running
`xdg-desktop-portal` and a backend implementation, and several of them show a
dialog a human has to answer. **They have not been run as part of this
repository's automation, and CI does not claim otherwise.** Run them before
tagging a release, and record the results in the release notes.

Run the demo project (`demo/demo.tscn`) and work through the list. Its log pane
shows exactly what the portal answered.

| # | Check | Expected |
| --- | --- | --- |
| 1 | Launch the demo on GNOME, KDE and a wlroots compositor. | The status line names the `native` backend and lists the interfaces each desktop exports. |
| 2 | With `gamemoded` installed: *Query GameMode* → *Request GameMode* → *Query GameMode*. | `not registered`, then `ok`, then `registered`. |
| 3 | Without `gamemoded`: *Request GameMode*. | Reports failure — not a silent success. |
| 4 | *Inhibit idle + suspend*, then leave the machine idle past its blank timeout. | The screen does not blank. `request_completed` reports `success`. |
| 5 | *Close inhibition*, then idle again. | The screen blanks normally. |
| 6 | *Read power saver* on a laptop, then toggle power-saver mode in the desktop settings. | The reported value matches, and `power_saver_changed` fires on the toggle. |
| 7 | *Open URI* with `https://godotengine.org`. | The default browser opens it; `request_completed` reports `success`. |
| 8 | *Open URI* with **Ask** ticked. | The "open with" chooser appears. Dismissing it reports `cancelled`, not `success`. |
| 9 | *Open URI* with `file:///etc/passwd`. | Rejected locally with a `portal_error`; no dialog, no bus traffic. |
| 10 | *Scheme supported?* for `https`, then for a nonsense scheme, on a portal older than 1.16. | `true`, `false`, and `unknown` on the old portal — never a guess. |
| 11 | *Post notification*, then activate it from the notification centre. | The notification appears with the right title/body; `notification_action_invoked` fires. |
| 12 | *Withdraw notification* while it is still on screen. | It disappears. |
| 13 | Repeat 1–12 inside a Flatpak built with only `--socket=session-bus` and `--talk-name=org.freedesktop.portal.Desktop`. | Identical behaviour; no additional permission needed. |
| 14 | Quit the demo while an inhibition is active. | The inhibition is released with the process; no stuck idle-inhibitor remains. |
| 15 | `systemctl --user restart xdg-desktop-portal` while the demo runs, then call `refresh_capabilities()`. | No crash; capabilities are re-discovered. |

If a check fails, `XDG_PORTALS_DEBUG=1` traces subscriptions, async replies and
incoming responses on stderr.

## Tier 4 — the macOS checklist (cannot run in CI)

The macOS backend implements one capability, so its checklist is short — but it
cannot be shortened to nothing. GitHub's macOS runners have no battery, so Low
Power Mode never flips there: CI proves the library builds universal, exports
its entry point and links only Foundation, and nothing beyond that. Everything
below needs a real Mac, and a laptop for rows 3 and 4.

| # | Check | Expected |
| --- | --- | --- |
| 1 | Launch the demo on macOS. | The status line names the `macos` backend and lists PowerProfileMonitor only. |
| 2 | *Query GameMode*, *Inhibit*, *Open URI*, *Post notification*. | Every one reports unavailable. None crashes, none reports a success. |
| 3 | *Read power saver* with Low Power Mode off, then on. | `false`, then `true` — never `null`, which on this backend would mean the read failed. |
| 4 | Toggle Low Power Mode in System Settings while the demo runs. | `power_saver_changed` fires with the new state, on the main thread. |
| 5 | Toggle Low Power Mode repeatedly, then quit the demo. | No crash on exit; the observer is removed before the object is released. |
| 6 | Run on an Apple Silicon Mac and an Intel Mac (or under Rosetta). | Identical behaviour; the universal library loads on both. |

Row 5 is the one worth taking seriously: the notification block captures the
monitor and is delivered on a queue the object owns, so a botched teardown shows
up as a crash on quit rather than as a wrong value.

## What is deliberately not automated

- Anything that shows UI a human must answer (checks 4, 5, 8, 11, 12).
- Desktop-specific behaviour differences (check 1) — CI has no GNOME, KDE or
  wlroots session.
- Flatpak sandbox behaviour (check 13) — this needs a built Flatpak and a real
  portal, not a container with a fake bus.
- Hardware-dependent behaviour (check 6) — power-profiles-daemon needs a battery
  to report anything meaningful.

Automating these would mean asserting against a fixture that answers however we
told it to, which is what tier 2 already does honestly. Pretending it is the
same as a desktop run would be worse than not running it.
