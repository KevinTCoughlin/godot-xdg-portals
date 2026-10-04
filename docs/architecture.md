# Architecture

The addon is three layers. Game code only ever sees the first.

```
┌──────────────────────────────────────────────────────────────┐
│ 1. Facade — addons/xdg_portals/desktop_services.gd                 │
│    Autoload `DesktopServices`. Typed API, enums, argument          │
│    validation, capability gating, signal re-emission.        │
└───────────────────────────┬──────────────────────────────────┘
                            │ DesktopServicesBackend contract
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│ NativeBackend │   │  NullBackend  │   │  MockBackend  │
│ (adapter)     │   │ (everywhere   │   │ (tests)       │
│               │   │  else)        │   │               │
└───────┬───────┘   └───────────────┘   └───────────────┘
        │ 2. GDExtension boundary
        ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. XdgPortalNative — src/*.cpp, C++17 + GIO                  │
│    Private GDBusConnection, private GMainContext, one worker │
│    thread. Talks to org.freedesktop.portal.Desktop.          │
└──────────────────────────────────────────────────────────────┘
```

## Layer 1 — the GDScript facade

`DesktopServices` is the stable surface. It is deliberately small and does four things
no backend should have to repeat:

- **Validation.** Inhibit flag masks, URI schemes, notification ids and
  priorities are checked before anything reaches the bus. A rejected call never
  produces bus traffic.
- **Capability gating.** Every method checks `has_capability()` first, so a
  missing interface produces an honest "unavailable" answer instead of a D-Bus
  error the caller has to interpret.
- **Type translation.** Godot enums in, portal wire values out
  (`NotificationPriority.HIGH` → `"high"`), and `-1` sentinels back into `null`.
- **Signal fan-out.** Backend signals are re-emitted from the autoload so game
  code connects in one place and keeps working across a backend swap.

It picks its backend on first use rather than only in `_ready()`, so an autoload
that reaches `DesktopServices` from its own `_ready()` still gets a working facade.

## Layer 2 — backends

`DesktopServicesBackend` is the contract: plain methods, four signals, and an honest
default for every one of them (`-1`, `false`, `""`). Three implementations ship:

| Backend | When | Behaviour |
| --- | --- | --- |
| `DesktopServicesNativeBackend` | Linux, extension loaded, session bus reachable | Forwards to `XdgPortalNative`. |
| `DesktopServicesNullBackend` | Everything else | Every call is a no-op reporting "unavailable". |
| `DesktopServicesMockBackend` | Injected by tests | Records calls, answers from `next_*` fields, emits signals on demand. |

Selection happens in `DesktopServices._create_default_backend()`:

1. Not Linux, or a web build → null backend, with the platform named in the
   reason.
2. `XdgPortalNative` not registered in `ClassDB` (no native library for this
   platform or build target) → null backend.
3. Native class present but the session bus is unreachable (headless container,
   no `DBUS_SESSION_BUS_ADDRESS`) → null backend, carrying GLib's own message.
4. Otherwise → native backend.

Because step 2 is a `ClassDB` lookup rather than a load, the addon imports and
runs on Windows, macOS, iOS, Android and web with no native library present at
all.

## Layer 3 — the native extension

`XdgPortalNative` is a `RefCounted` GDExtension class over GLib/GIO. It never
shells out; there is no `dbus-send`, `gdbus` or `busctl` anywhere in the build.

### Connection

The extension opens its **own private** `GDBusConnection` via
`g_dbus_address_get_for_bus_sync()` + `g_dbus_connection_new_for_address_sync()`
rather than the shared `g_bus_get_sync()` singleton, so it cannot disturb any
other GLib user inside the process. `exit_on_close` is disabled: a bus that goes
away must not take the game down.

### Threading

The connection is created while a private `GMainContext` is thread-default, and
one worker thread runs a `GMainLoop` on that context. Connecting is asynchronous
and bounded by `CONNECT_TIMEOUT_MS`: a session bus that accepts the socket and
then never answers makes the backend unavailable after five seconds instead of
hanging the game. That is where every
incoming D-Bus message is dispatched. Results reach Godot through
`call_deferred("emit_signal", …)`, so script code only ever sees signals on the
main thread.

Two rules follow from this, and both are load-bearing:

1. **Anything that captures the thread-default context must run on the worker.**
   `g_dbus_connection_call()` dispatches its reply through the context that was
   thread-default when it was called, and
   `g_dbus_connection_signal_subscribe()` resolves a well-known sender name to
   its unique name through that same context. Issued from Godot's main thread
   they attach to GLib's global default context, which nothing in a Godot
   process iterates — replies never arrive, and subscribed signals silently
   never match their sender. `run_on_worker()` marshals these calls onto the
   worker and waits, bounded.
2. **Nobody else may push that context.** The running loop *owns* it, so
   `g_main_context_push_thread_default()` from another thread fails (GLib logs
   `assertion 'acquired_context' failed`) and leaves the wrong context in place —
   which looks exactly like rule 1 being violated. This is why `run_on_worker()`
   marshals instead of pushing.

Both rules were learned the hard way; `tests/native/native_smoke.gd` is the
regression test that keeps them honest.

### Synchronous versus interactive calls

Only **non-interactive** calls are synchronous, and each has a bounded 2-second
timeout (`SYNC_CALL_TIMEOUT_MS`): GameMode's three methods, `SchemeSupported`,
the two Notification methods, and `Request.Close`. None of them show UI, so none
of them can block on a human. `g_dbus_connection_call_sync()` drives its own
temporary context, so these do not depend on the worker loop at all.

Property reads (interface versions and the power-saver state) are issued
together, asynchronously on the worker, and waited for under a single
`SYNC_CALL_TIMEOUT_MS`, so a slow portal costs startup one timeout rather than
one per read. Versions are cached per portal instance.

**Interactive** calls — `Inhibit` and `OpenURI` — are never synchronous. They
follow the portal request pattern:

1. Generate a `handle_token` and derive the request object path from the
   connection's own unique bus name
   (`/org/freedesktop/portal/desktop/request/<escaped unique name>/<token>`),
   and record it as the request's path.
2. Issue the call asynchronously and return the handle immediately.
3. When the reply arrives, if the portal chose a different path than predicted,
   record the real path, then drop the predicted one.
4. On `Response`, look the path up and emit `request_completed` for the
   caller's handle.

One subscription, made when the worker starts, receives every
`org.freedesktop.portal.Request::Response` from the portal, whatever its path.
Subscribing per path, before each call, is what the specification suggests, but
it cannot work for a portal that answers on a path other than the predicted
one: the client learns that path from the reply, and a match rule added then
can be overtaken by a `Response` sent straight after the reply. A `Response`
that arrives before the reply naming its path is held, briefly and boundedly,
until the reply claims it.

A request always completes. If the call itself fails, or the portal's name
loses its owner or changes owner before the `Response`, the request is
completed locally with `Response.OTHER`, so a caller awaiting a handle is never
stranded.

### Portal lifecycle

The worker subscribes to `PropertiesChanged` and `ActionInvoked`
unconditionally, and watches the portal's bus name. The subscriptions name the
portal's well-known name as their sender, so GLib follows whichever process owns
it: a portal that was slow or absent at startup, or that restarts, is still
heard. When the name's owner goes away or changes, pending requests are failed
as above, the cached interface versions are dropped, and the power-saver state
is marked unknown and re-read from the new owner.

### Type conversion

`src/gvariant_conv.cpp` converts `GVariant` to Godot `Variant` in one direction
only. There is deliberately no general Godot→`GVariant` converter: notification
payloads are assembled from a fixed set of fields, and no API path lets game code
construct an arbitrary D-Bus message. That is what keeps "no unsafe arbitrary
D-Bus invocation" a structural property rather than a policy.

### Shutdown

`teardown()` cancels the shared `GCancellable` and quits the loop. The worker
then unsubscribes everything, closes the connection, and drains its context, so
every cancelled call's reply is delivered and frees its payload, and every
queued task that never ran releases what it captured. Only then is the worker
joined and anything released. Because callbacks only run on the worker and the
worker is joined before any member is released, no callback can observe a
half-destroyed object.

## Debugging

Set `XDG_PORTALS_DEBUG=1` to trace subscriptions, async replies and incoming
responses on stderr. Portal services log to the session journal, so without this
a mismatch between what was sent and what came back is guesswork.
