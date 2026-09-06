# godot-xdg-portals

Typed, sandbox-safe access to selected [XDG Desktop Portal](https://flatpak.github.io/xdg-desktop-portal/)
APIs from Godot 4.4+, as a GDExtension plus a small GDScript facade.

It works on native Linux and inside Flatpak, hides D-Bus entirely from game
code, and degrades safely everywhere else: on Windows, macOS, mobile, web and
headless Linux without a session bus, the addon loads a null backend and every
call reports "unavailable" instead of crashing.

- Repository: <https://github.com/KevinTCoughlin/godot-xdg-portals>
- License: MIT (see [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md))

## Portal coverage

| Portal interface | What the addon uses | Godot API |
| --- | --- | --- |
| `org.freedesktop.portal.GameMode` | `QueryStatus`, `RegisterGame`, `UnregisterGame` | `query_game_mode()`, `request_game_mode()`, `release_game_mode()` |
| `org.freedesktop.portal.Inhibit` | `Inhibit`, plus `org.freedesktop.portal.Request.Close` | `inhibit()`, `close_request()` |
| `org.freedesktop.portal.PowerProfileMonitor` | `power-saver-enabled` property and its change notifications | `is_power_saver_enabled()`, `power_saver_changed` |
| `org.freedesktop.portal.OpenURI` | `OpenURI`, and `SchemeSupported` on interface version 5+ | `open_uri()`, `is_scheme_supported()` |
| `org.freedesktop.portal.Notification` | `AddNotification`, `RemoveNotification`, `ActionInvoked` | `add_notification()`, `remove_notification()`, `notification_action_invoked` |

Everything goes through `org.freedesktop.portal.Desktop` at
`/org/freedesktop/portal/desktop` using GLib/GIO directly. The addon never
shells out to `dbus-send`, `gdbus`, `busctl` or desktop-specific helpers, and it
exposes no way to make an arbitrary D-Bus call.

## Requirements

- Godot 4.4 or newer
- Linux with a running `xdg-desktop-portal` service, for the native backend
- GLib/GIO 2.66+ at runtime (already present on any modern desktop and in the
  Flatpak runtimes)

## Installation

### From a release archive

1. Download `godot-xdg-portals-<version>-linux-x86_64.zip` from the
   [releases page](https://github.com/KevinTCoughlin/godot-xdg-portals/releases)
   and verify it against the published `.sha256` file.
2. Extract its `addons/xdg_portals` directory into your project's `addons/`.
3. Enable **XDG Portals** in *Project → Project Settings → Plugins*. The plugin
   installs the `XDGPortal` autoload for you.

The archive contains the addon (GDScript facade, backends, `.gdextension`
descriptor), the prebuilt Linux x86-64 libraries for all three targets —
`template_release`, `template_debug` and `editor`, the last so the native
backend is active when you run your project from the Godot editor — plus
`README.md`, `LICENSE`, `CHANGELOG.md` and `THIRD_PARTY_NOTICES.md`.

### From source

```bash
git clone https://github.com/KevinTCoughlin/godot-xdg-portals.git
cd godot-xdg-portals
sudo apt-get install build-essential cmake pkg-config libglib2.0-dev  # Debian/Ubuntu
./scripts/build.sh --target template_release
```

Then copy `addons/xdg_portals` into your project. Build the `editor` target as
well if you want the native backend active while running from the Godot editor:

```bash
./scripts/build.sh --target editor
```

`scripts/build.sh` fetches godot-cpp pinned to `godot-4.4.1-stable`. Point it at
an existing checkout with `--godot-cpp /path/to/godot-cpp` to skip the download.

## Usage

The plugin installs a single autoload, `XDGPortal`. Ask what is available before
using it — a portal that is not exported is reported honestly rather than
emulated.

```gdscript
func _ready() -> void:
    if not XDGPortal.is_available():
        print("No portals here: %s" % XDGPortal.get_unavailable_reason())
        return

    XDGPortal.request_completed.connect(_on_request_completed)
    XDGPortal.power_saver_changed.connect(_on_power_saver_changed)

    if XDGPortal.has_capability(XDGPortal.Capability.GAME_MODE):
        XDGPortal.request_game_mode()


var _inhibit_handle := ""

func begin_cutscene() -> void:
    var flags := XDGPortal.InhibitFlags.IDLE | XDGPortal.InhibitFlags.SUSPEND
    _inhibit_handle = XDGPortal.inhibit(flags, "Playing a cutscene")

func end_cutscene() -> void:
    if not _inhibit_handle.is_empty():
        XDGPortal.close_request(_inhibit_handle)
        _inhibit_handle = ""


func open_manual() -> void:
    # Returns a request handle; the outcome arrives on `request_completed`.
    XDGPortal.open_uri("https://example.com/manual")

func _on_request_completed(handle: String, response: int, results: Dictionary) -> void:
    if response == XDGPortal.Response.SUCCESS:
        print("%s succeeded: %s" % [handle, results])


func _on_power_saver_changed(enabled: bool) -> void:
    Engine.max_fps = 30 if enabled else 0
```

Unknown state is always represented honestly:

```gdscript
var saving: Variant = XDGPortal.is_power_saver_enabled()
if saving == null:
    pass  # The portal could not tell us; do not guess.
elif saving:
    reduce_quality()
```

See [`docs/api.md`](docs/api.md) for the complete reference and
[`demo/demo.tscn`](demo/demo.tscn) for a runnable example of every call.

## Flatpak

Portal calls are the *supported* way to reach the host from a sandbox, so no
broad D-Bus permission is needed. Grant only the portal endpoint:

```yaml
finish-args:
  - --socket=session-bus            # required to reach the portal service
  - --talk-name=org.freedesktop.portal.Desktop
```

Do **not** add `--talk-name=org.freedesktop.*` or `--socket=system-bus`: this
addon needs neither, and both hand the sandbox far more than portal access.
GameMode requests are forwarded by the portal to the host `gamemoded`; the
sandbox never talks to `com.feralinteractive.GameMode` itself.

Notification actions arrive through the same portal connection, so no extra
permission is required for them either.

## Testing

```bash
./scripts/run_tests.sh          # uses `godot` from PATH, or $GODOT
```

The suite is entirely mock-backed and deterministic: it injects an
`XDGPortalMockBackend`, so it needs no session bus, no display and no portal
service, and behaves identically on a laptop and on CI.

Testing the *native* backend against a real portal service cannot be done in
CI — it needs a graphical Linux session with `xdg-desktop-portal` running, and
several calls show UI a human must answer. Those checks are written up as a
manual checklist in [`docs/native-testing.md`](docs/native-testing.md).

## Documentation

- [`docs/api.md`](docs/api.md) — every method, signal and enum
- [`docs/architecture.md`](docs/architecture.md) — the three layers and the threading model
- [`docs/compatibility.md`](docs/compatibility.md) — platforms, portal versions, desktop support
- [`docs/native-testing.md`](docs/native-testing.md) — the manual desktop checklist
- [`docs/roadmap.md`](docs/roadmap.md) — what is planned and what is deliberately out of scope

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Contributions are accepted under the
[Developer Certificate of Origin](DCO.txt): sign off your commits with
`git commit -s`.
