# Roadmap

The goal is a small, boring, dependable addon. Growth is measured against one
question: does this belong behind a *typed, mockable* Godot API, or is it
better served by the raw portal?

## 0.1.0 — current

Five portal interfaces (GameMode, Inhibit, PowerProfileMonitor, OpenURI,
Notification), a null backend everywhere else, a mock backend for tests, a
CMake build pinned to godot-cpp 4.4.1, and prebuilt Linux x86-64 libraries in the
release archive.

## 0.2.0 — candidates

- **Notification buttons and default actions.** `AddNotification` accepts a
  `buttons` array and a `default-action`; the facade currently posts title, body
  and priority only. This needs an API that stays typed without turning into a
  general `a{sv}` builder.
- **Inhibit session state monitoring.** `org.freedesktop.portal.Inhibit` also
  offers `CreateMonitor` and the `StateChanged` signal for
  screensaver-active/session-running state. Useful for pausing on lock.
- **Prebuilt Linux arm64 libraries.** The build already supports arm64; the
  release workflow does not cross-compile yet.
- **Godot 4.5 in the CI matrix**, once it is the widely deployed version.

## Under consideration

- **`org.freedesktop.portal.Screenshot`** — a natural fit for a bug-report
  button, but the result is a file URI, and handling that safely deserves its own
  design pass rather than being bolted onto `open_uri()`.
- **`org.freedesktop.portal.FileChooser`** — genuinely useful for save/load in
  sandboxed games, and the largest single addition on this list: it returns file
  descriptors through the document portal, which changes the security surface.
- **`org.freedesktop.portal.Settings`** — reading the desktop's colour scheme to
  match the game UI to light/dark.

## Explicitly out of scope

- **A generic D-Bus bridge.** Exposing arbitrary bus calls would undo the reason
  this addon exists: game code cannot construct a D-Bus message through this API,
  and there is no Godot→`GVariant` converter for it to use. Projects that need a
  general bus client should use one.
- **Non-portal interfaces.** Talking to `com.feralinteractive.GameMode`,
  `org.freedesktop.ScreenSaver` or `org.freedesktop.login1` directly would work
  on the host and break in a sandbox, and would require exactly the broad
  `--talk-name` permissions this addon avoids.
- **Windows or macOS equivalents.** "Inhibit sleep on any platform" is a
  different, larger library. Here, non-Linux is the null backend and says so.
- **Vendoring GLib.** It is linked dynamically from the host or Flatpak runtime;
  bundling it would break LGPL relinking expectations for no benefit.

## Maintenance policy

- **godot-cpp** is pinned by tag in `CMakeLists.txt`
  (`XDG_PORTALS_GODOT_CPP_TAG`). Dependabot cannot track a tag pinned this way,
  so it is reviewed by hand each time the minimum supported Godot version moves.
  It is bumped deliberately, never automatically: raising it raises the engine
  floor for every consumer.
- **GitHub Actions** are updated weekly by Dependabot, grouped into one PR.
- **The portal interfaces** are versioned by the portal itself. New optional
  members are adopted behind a version check, the way `SchemeSupported` is
  gated on `OpenURI` version 5 — never assumed present.
- **Semantic versioning.** Before 1.0 the public API may change in a minor
  release; every change is listed in [`../CHANGELOG.md`](../CHANGELOG.md).

## Before 1.0

- The desktop checklist in [`native-testing.md`](native-testing.md) run on
  GNOME, KDE and a wlroots compositor, plus a Flatpak build, with the results
  recorded in the release notes.
- At least one shipped game using it in anger.
