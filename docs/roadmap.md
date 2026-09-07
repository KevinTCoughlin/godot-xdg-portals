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
- **C# support for the .NET flavour of the engine.** See below; the native
  layer already works there, so this is a binding and packaging question
  rather than a portal one.

## C# support

The GDExtension itself needs no changes: extension loading is engine-level and
independent of the scripting language, so `libxdg_portals.linux.*.so` already
loads in a Godot .NET build. What is missing is a usable API on top of it.

As of Godot 4.4, C# bindings are generated only for core engine classes, so
GDExtension types are reachable from C# only dynamically:

```csharp
var portal = GetNode("/root/XDGPortal");
var handle = portal.Call("inhibit", 8, "Cutscene").AsString();
```

That works today with no change to this repository, but it is stringly typed,
has no enums, and — most importantly — turns the `null`-means-unknown contract
into a bare `Variant` that is easy to misread as `false`. That contract is the
whole point of the addon, so a C# surface that loses it is worse than none.

**Shape.** A thin typed shim over the *GDScript facade*, not over
`XdgPortalNative` directly. All the logic worth having — argument validation,
capability gating, `file:` rejection, enum mapping, honest returns, backend
selection — lives in the facade. Reimplementing it in C# would mean two
implementations of the honesty rules drifting apart, which is exactly the kind
of difference that must not exist between languages. The cost is one `Variant`
marshal per call, irrelevant for calls made a handful of times per session.

`bool?` maps the tri-state better than GDScript can express it:

```csharp
public static bool? IsPowerSaverEnabled()
{
    var v = _portal.Call("is_power_saver_enabled");
    return v.VariantType == Variant.Type.Nil ? null : v.AsBool();
}
```

**What it entails.**

| Work | Size |
| --- | --- |
| `XdgPortal.cs` shim: methods, `[Flags] InhibitFlags`, the other enums, `event` wrappers over the signals via `Callable.From<>` | ~300–400 lines, straightforward |
| A test asserting the C# enum values match the GDScript constants at runtime | small, and essential — this is the drift hazard |
| A separate C# demo/test project | the real structural cost, see below |
| CI job: .NET SDK plus the `mono`/.NET Godot build | new download, roughly doubles the CI matrix |
| A C# section in `docs/api.md` and a compatibility note | small |

**The structural cost.** A Godot .NET project needs a `.csproj`, and this
repository root *is* the test-bed project. Adding one there would force
GDScript-only users onto the .NET editor build. So the C# side needs its own
project directory referencing the addon, which means the addon is consumed two
different ways in one repository.

**Gotchas.**

- The tri-state must survive the boundary: `Variant.Type.Nil` maps to `null`,
  never `false`.
- `request_completed` results arrive as `Godot.Collections.Dictionary`; a typed
  result object is extra design work.
- Anything polled per frame (`IsPowerSaverEnabled()`) now pays a `Variant` hop,
  so the shim should cache off the `PowerSaverChanged` event and say so.
- C# event subscriptions to a GDScript autoload need explicit unsubscribe, or
  the delegates outlive the scene.

The mock backend stays usable from C# — `set_backend()` accepts any backend
object — so this does not compromise testability.

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
