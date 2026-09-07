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
var portal = GetNode("/root/DesktopServices");
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

## Windows and macOS variants

Non-Linux is the null backend today, and that is a contract rather than a stub:
the addon imports, the autoload installs, and every call reports "unavailable"
with the platform named. The question is whether a *native* Windows and macOS
variant should exist behind the same facade. Mostly not — and it is worth being
precise about which parts, because "just call the platform API instead" is only
true for one of the five interfaces. Two are worth reconsidering; three are not,
on grounds that no amount of effort changes.

**Per interface.** Two have clean equivalents, one is already covered by the
engine, one has no equivalent at all, and one changes what shipping a Godot game
looks like.

| Capability | macOS | Windows | Verdict |
| --- | --- | --- | --- |
| `GAME_MODE` | Game Mode (14+) is chosen by the OS for full-screen apps that set `GCSupportsGameMode`; no query, no request | Game Mode is chosen by the OS and toggled by the user in Settings; no public API | **No equivalent.** Permanently absent capability on both. |
| `INHIBIT` | `IOPMAssertionCreateWithName` / `IOPMAssertionRelease` | `PowerCreateRequest` + `PowerSetRequest` / `PowerClearRequest` | Handle-based on both, so it maps cleanly — but see the flag problem below. |
| `POWER_PROFILE_MONITOR` | `NSProcessInfo.isLowPowerModeEnabled` + `NSProcessInfoPowerStateDidChangeNotification` | `GetSystemPowerStatus().SystemStatusFlag` + `RegisterPowerSettingNotification(GUID_POWER_SAVING_STATUS)` | **The best fit of the five**, including a real change notification on both. |
| `OPEN_URI` | `NSWorkspace.open(_:)` | `ShellExecuteExW` | Already what `OS.shell_open()` does. Only `is_scheme_supported()` (`NSWorkspace.urlForApplication(toOpen:)`, `AssocQueryStringW`) is new. |
| `NOTIFICATION` | `UNUserNotificationCenter` | Toast notifications via an AUMID | Works, but imposes packaging requirements on the consuming game. See below. |

**Three specific problems**, in ascending order of how much they cost:

1. **`inhibit()` stops being all-or-nothing.** `InhibitFlags` is a mask of
   logout, user-switch, suspend and idle. Both platforms cover idle and suspend
   (`kIOPMAssertionTypePreventUserIdleDisplaySleep` /
   `…PreventUserIdleSystemSleep`; `PowerRequestDisplayRequired` /
   `PowerRequestSystemRequired`). Neither covers user-switch. Logout exists only
   on Windows, through `ShutdownBlockReasonCreate`, which needs an `HWND` and is
   a different mechanism with a different lifetime. So a call asking for all four
   would silently honour two — and quietly dropping bits is the fabricated
   success this addon refuses. It would need an answer at the API level, not a
   footnote.

2. **`open_uri()` loses its request model.** The portal answers asynchronously
   and can report that the user cancelled. `NSWorkspace.open` and
   `ShellExecuteExW` are fire-and-forget: there is no outcome to wait for. A
   backend that emitted `request_completed` with `Response.SUCCESS` immediately
   would be inventing an answer. Since `OS.shell_open()` already covers the
   actual opening on every platform, the honest version of this is "not
   available here", which is what happens now.

3. **Notifications move the cost into the consuming project.** On macOS,
   `UNUserNotificationCenter` requires a signed `.app` bundle with a bundle
   identifier and a user authorization prompt — it does not work for a bare
   executable or when running from the editor. On Windows, an unpackaged app
   needs an AUMID backed by a Start Menu shortcut before a toast will display at
   all, or MSIX identity if packaged; round-tripping `notification_action_invoked`
   back into the running process needs a registered COM activator on top of that.
   Both are export-pipeline requirements, so the addon would be telling games how
   to ship. The Linux portal asks for none of this.

**What it would entail.**

| Work | Size |
| --- | --- |
| `IOKit`/`Foundation` Objective-C++ backend, `powrprof`/`shell32`/WinRT Win32 backend | the smallest part |
| A neutral facade name and capability enum, since `Capability` maps 1:1 to `org.freedesktop.portal.*` interface names | breaking change for every consumer |
| Three toolchains in CMake and CI, a universal `.dylib` (x86-64 + arm64), codesigning for macOS notifications | roughly triples build and release surface |
| A manual desktop checklist per platform | recurring, per release |

**The verification cost.** The existing suite is mock-backed and deterministic,
and the native path already cannot be tested in CI — `native-testing.md` is a
manual checklist run by a human on a real session. Two more platforms means two
more such checklists. Untested native code that ships is worse than an honest
null backend, so this is the cost that governs, and it is recurring rather than
one-time: every release pays it again, on every platform.

Hosted CI covers less of it than it looks. GitHub's macOS and Windows runners
can build the extension and smoke-test that a power assertion is created and
released cleanly, which is worth having and is automatable. They cannot exercise
the state transitions: neither runner has a battery, so Low Power Mode and
Battery Saver never flip. Those stay manual, on real hardware, exactly as the
Linux rows are today.

**The narrow shape**, should this be taken up: power-saver state and
system-sleep inhibition — the two that map cleanly — behind a neutral facade
name, with the portal path as the Linux backend rather than the core. GameMode,
OpenURI and Notification stay out on the grounds above, and no hardware changes
that: two of them have nothing to call, and the third moves cost onto every
consuming game.

Two things would have to be settled before any such code, and neither is about
platform APIs:

- **The facade name.** `DesktopServices`, and a `Capability` enum mapping 1:1 to
  `org.freedesktop.portal.*` interface names, cannot honestly front a Win32
  backend. Pre-1.0 this is a permitted break, but it is a break, and it wants
  deciding first rather than during.
- **What `inhibit()` promises.** `get_supported_inhibit_flags()`, or some
  equivalent, so a caller can find out that user-switch is unavailable on both
  platforms and logout only on Windows. Note this cannot become a report of what
  was actually *honoured*: the portal returns a request handle and never
  enumerates the bits it acted on, so a compositor silently ignoring the logout
  bit is unobservable on Linux too. Statically declaring what a backend can
  request is answerable; reporting what the session did with it is not.

Note also that `DisplayServer.screen_set_keep_on()` already handles display
sleep on all three platforms in the engine itself, so the cross-platform slice
worth building is smaller than the table suggests.

## Capability vocabulary

The backend contract reports availability through `get_interface_versions()`,
keyed by `org.freedesktop.portal.*` interface names, and the facade derives
`has_capability()` from it. That was exact while every backend was a portal. It
is not any more: the macOS backend has to answer in a vocabulary describing
D-Bus interfaces it does not have, and says so in a comment rather than
pretending.

Renaming the facade to `DesktopServices` fixed the name a game sees. It did not
fix this. The change that does is to split the two questions the dictionary
currently conflates:

- `get_capabilities()` on the backend — which capabilities are usable, keyed by
  `Capability`. Every backend can answer this honestly.
- `get_interface_version(capability)` — the portal interface version, and a
  portal-specific extra rather than the mechanism. `-1` on any backend that is
  not a portal, which is already what it means when an interface is absent.

The facade's public surface barely moves: `has_capability()` reads the first,
`get_interface_version()` the second, both already exist. The work is in the
four backends and their tests. Worth doing before a second non-portal backend
makes the same compromise twice.

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
- **Windows or macOS equivalents of GameMode, OpenURI and Notification.** Two
  have no API to call at all; the third would impose export-pipeline
  requirements on every consuming game. Power-saver state and system-sleep
  inhibition are a narrower question and are treated separately in
  [Windows and macOS variants](#windows-and-macos-variants) above; everything
  else non-Linux is the null backend and says so.
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
