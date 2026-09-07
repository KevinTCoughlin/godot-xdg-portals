# API reference

Everything a game needs is on the `DesktopServices` autoload, installed by the
`xdg_portals` plugin (`res://addons/xdg_portals/desktop_services.gd`).

The API has one rule that governs every return value: **an unavailable operation
is never reported as a success.** Reads that cannot be answered return `null` or
`GameModeStatus.UNKNOWN`; operations that did not happen return `false` or an
empty handle.

## Discovery

| Member | Returns | Notes |
| --- | --- | --- |
| `is_available()` | `bool` | Whether portal calls can be attempted at all. |
| `get_unavailable_reason()` | `String` | Empty when available; otherwise why not. |
| `get_backend_name()` | `String` | `"native"`, `"macos"`, `"null"` or `"mock"`. |
| `get_backend()` | `DesktopServicesBackend` | The active backend. |
| `set_backend(backend)` | `void` | Injects a backend; see [Testing](#testing). |
| `refresh_capabilities()` | `void` | Re-reads capabilities from the backend, emits `capabilities_changed`. |
| `get_capabilities()` | `Dictionary` | `Capability` → `bool`. |
| `has_capability(capability)` | `bool` | Whether that capability is usable. |
| `get_interface_version(capability)` | `int` | Portal interface version, or `-1` when there is none. |

`has_capability()` is the question to ask. It comes from the backend, so it is
answerable whatever the backend is built on — the macOS backend serves
`POWER_PROFILE_MONITOR` and nothing else, without any portal interface existing.

`get_interface_version()` is a **portal-specific extra**, not the mechanism. Any
backend that is not a portal answers `-1` for everything while still serving its
capabilities, so `get_interface_version(c) >= 0` is *not* an availability check.
Use it for diagnostics, and for gating on a portal member that needs a minimum
version — `SchemeSupported` is the only such case here.

Capability discovery runs once at backend selection. Call
`refresh_capabilities()` if the portal service is restarted mid-session.

## GameMode

```gdscript
func query_game_mode(pid: int = 0) -> GameModeStatus
func request_game_mode(pid: int = 0) -> bool
func release_game_mode(pid: int = 0) -> bool
```

`pid` defaults to `0`, meaning the current process (`OS.get_process_id()`).

`query_game_mode()` returns `GameModeStatus.UNKNOWN` when the status could not be
determined, including when the portal answers with a code this addon does not
recognise. `request_game_mode()` and `release_game_mode()` return `true` only for
the portal's documented success code (`0`).

These three calls are synchronous with a 2-second timeout — they are
non-interactive and show no UI.

## Inhibit

```gdscript
func inhibit(flags: int, reason: String, parent_window: String = "") -> String
func get_supported_inhibit_flags() -> int
func close_request(handle: String) -> bool
```

`flags` is a mask of `InhibitFlags`. A mask of `0`, a negative value, or any bit
outside `INHIBIT_FLAGS_MASK` is rejected locally: the call returns `""`, emits
`portal_error`, and nothing reaches the bus.

`get_supported_inhibit_flags()` returns the mask the current backend can *ask*
for, or `0` when inhibition is unavailable. Against a portal that is every
documented bit; it is lower only on a backend that cannot express one.

```gdscript
var wanted := DesktopServices.InhibitFlags.IDLE | DesktopServices.InhibitFlags.SUSPEND
if wanted & DesktopServices.get_supported_inhibit_flags() == wanted:
    handle = DesktopServices.inhibit(wanted, "Cutscene")
```

It does not gate `inhibit()`, and it is not a report of what the session did.
The portal answers `Inhibit` with a request handle and never enumerates the bits
it acted on, so a desktop that ignores one it advertises is indistinguishable
from one that honours it — wlroots compositors commonly ignore logout and
user-switch (see [`compatibility.md`](compatibility.md#desktop-support)). Treat
the result as "what can be requested here", never as "what will happen".

`inhibit()` returns immediately with a request handle — the portal's eventual
answer arrives on `request_completed`. The inhibition stays in effect until the
handle is closed with `close_request()` (which calls
`org.freedesktop.portal.Request.Close`) or the application exits.

`parent_window` is the portal window identifier of the window the request
belongs to (`"x11:<hex xid>"` or `"wayland:<handle>"`). An empty string means
"no parent", which is correct for a fullscreen game.

## PowerProfileMonitor

```gdscript
func is_power_saver_enabled() -> Variant   # true, false, or null
signal power_saver_changed(enabled: bool)
```

Returns `null` when the state is unknown — the interface is missing, or the
property could not be read. The value is cached from the portal's property
change notifications, so reading it every frame costs nothing.

## OpenURI

```gdscript
func open_uri(uri: String, ask: bool = false, parent_window: String = "") -> String
func is_scheme_supported(scheme: String) -> Variant   # true, false, or null
```

`open_uri()` validates the URI before it goes anywhere:

- the scheme must match RFC 3986 (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`);
- `file:` is rejected **case-insensitively** (`file:`, `FILE:`, `FiLe:` alike).

A rejected URI returns `""` and emits `portal_error`. Otherwise the call returns
a request handle and the result arrives on `request_completed`.

Set `ask` to `true` to force the portal's "open with" chooser instead of the
user's default handler.

`is_scheme_supported()` returns `null` when the running portal cannot answer:
`SchemeSupported` only exists from `org.freedesktop.portal.OpenURI` version 5,
and older portals are reported as unknown rather than guessed. It returns `false`
for `file:` regardless of what the portal says, because this addon will not open
one.

## Notification

```gdscript
func add_notification(
    id: String,
    title: String,
    body: String = "",
    priority: NotificationPriority = NotificationPriority.NORMAL
) -> bool
func remove_notification(id: String) -> bool
signal notification_action_invoked(id: String, action: String, parameters: Array)
```

Reusing an `id` replaces the notification posted under it. An empty `id` is
rejected locally. Priorities map to the portal's string names: `"low"`,
`"normal"`, `"high"`, `"urgent"`.

`notification_action_invoked` forwards the portal's `ActionInvoked` signal.
`parameters` holds the D-Bus payload converted to Godot values.

## Signals

| Signal | Arguments | Emitted when |
| --- | --- | --- |
| `capabilities_changed` | — | A backend is selected or injected, or `refresh_capabilities()` runs. |
| `power_saver_changed` | `enabled: bool` | The desktop's power-saver state changes. |
| `request_completed` | `handle: String, response: int, results: Dictionary` | An interactive request finishes. |
| `notification_action_invoked` | `id: String, action: String, parameters: Array` | The user activates a notification action. |
| `portal_error` | `context: String, message: String` | A call fails or is rejected. `context` names the D-Bus member, e.g. `"OpenURI.OpenURI"`. |

If an interactive call fails outright, the addon still emits `request_completed`
for its handle with `Response.OTHER`, so a caller waiting on a handle is never
stranded.

## Enums

```gdscript
enum InhibitFlags { LOGOUT = 1, USER_SWITCH = 2, SUSPEND = 4, IDLE = 8 }
enum GameModeStatus { UNKNOWN = -1, NOT_REGISTERED = 0, REGISTERED = 1, REJECTED = 2 }
enum Response { SUCCESS = 0, CANCELLED = 1, OTHER = 2 }
enum NotificationPriority { LOW = 0, NORMAL = 1, HIGH = 2, URGENT = 3 }
enum Capability { GAME_MODE, INHIBIT, POWER_PROFILE_MONITOR, OPEN_URI, NOTIFICATION }
```

Constants: `INHIBIT_FLAGS_MASK` (`15`), `INTERFACE_NAMES` (`Capability` → portal
interface name — descriptive only; see above), `SCHEME_SUPPORTED_MIN_VERSION`
(`5`).

`Response` values match the portal's own response codes, so `SUCCESS` is `0` and
anything non-zero means the request did not do what was asked.

## Testing

Inject a mock backend to drive portal behaviour deterministically:

```gdscript
var mock := DesktopServicesMockBackend.new()
mock.next_game_mode_status = DesktopServices.GameModeStatus.REGISTERED
mock.next_power_saver_state = 1
DesktopServices.set_backend(mock)

DesktopServices.request_game_mode()
assert(mock.calls_to("game_mode_register").size() == 1)

# Complete an interactive request without any portal or timer involved.
var handle := DesktopServices.inhibit(DesktopServices.InhibitFlags.IDLE, "Cutscene")
mock.complete_request(handle, DesktopServices.Response.SUCCESS)
```

`DesktopServicesMockBackend` records every call in `calls` (and `calls_to(method)`),
answers from its `next_*` fields, and can emit any backend signal on demand via
`complete_request()`, `emit_power_saver()`, `emit_action()` and `emit_error()`.

`DesktopServicesNullBackend` is the other injectable backend: it is what the facade
selects wherever portals cannot exist, and it is useful for asserting that a
game behaves on a portal-less machine.
