# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends Node

## Typed, sandbox-safe access to selected XDG Desktop Portal APIs.
##
## This node is installed as the [code]DesktopServices[/code] autoload by the
## [code]xdg_portals[/code] plugin. It is the only class game code needs: it
## validates arguments, hides D-Bus entirely, and delegates to a backend that is
## chosen at startup ([DesktopServicesNativeBackend] on Linux with a session bus,
## [DesktopServicesNullBackend] everywhere else) or injected by tests
## ([DesktopServicesMockBackend]).
##
## Unknown state is reported honestly. Reads that cannot be answered return
## [code]null[/code] or [constant GameModeStatus.UNKNOWN]; operations that could
## not be performed return [code]false[/code] or an empty handle. No call ever
## reports success for something that did not happen.
##
## [codeblock]
## func _ready() -> void:
##     if DesktopServices.has_capability(DesktopServices.Capability.GAME_MODE):
##         DesktopServices.request_game_mode()
##     DesktopServices.request_completed.connect(_on_request_completed)
##     var handle := DesktopServices.inhibit(DesktopServices.InhibitFlags.IDLE, "Cutscene")
## [/codeblock]

## Emitted after backend selection or injection, once capabilities have been
## re-discovered.
signal capabilities_changed()

## Emitted when the desktop's power-saver state changes.
signal power_saver_changed(enabled: bool)

## Emitted when an interactive request finishes. [param response] is a
## [enum Response] value and [param handle] is the string returned by
## [method inhibit] or [method open_uri].
signal request_completed(handle: String, response: int, results: Dictionary)

## Emitted when the user activates an action on a notification posted with
## [method add_notification].
signal notification_action_invoked(id: String, action: String, parameters: Array)

## Emitted when a portal call fails. [param context] names the D-Bus member.
signal portal_error(context: String, message: String)


## Bit flags accepted by [method inhibit]. They may be combined with [code]|[/code].
enum InhibitFlags {
	LOGOUT = 1, ## Prevent the session from logging out.
	USER_SWITCH = 2, ## Prevent switching to another user session.
	SUSPEND = 4, ## Prevent the machine from suspending.
	IDLE = 8, ## Prevent the session from marking itself idle.
}

## Result of [method query_game_mode].
enum GameModeStatus {
	UNKNOWN = -1, ## The status could not be determined.
	NOT_REGISTERED = 0, ## The process is not registered with GameMode.
	REGISTERED = 1, ## The process is registered with GameMode.
	REJECTED = 2, ## GameMode refused the registration.
}

## Response code carried by [signal request_completed].
enum Response {
	SUCCESS = 0, ## The request completed successfully.
	CANCELLED = 1, ## The user dismissed the request.
	OTHER = 2, ## The request ended for any other reason, including failure.
}

## Priority accepted by [method add_notification].
enum NotificationPriority {
	LOW = 0,
	NORMAL = 1,
	HIGH = 2,
	URGENT = 3,
}

## Capability keys returned by [method get_capabilities].
enum Capability {
	GAME_MODE = 0,
	INHIBIT = 1,
	POWER_PROFILE_MONITOR = 2,
	OPEN_URI = 3,
	NOTIFICATION = 4,
}

## Every bit [method inhibit] accepts.
const INHIBIT_FLAGS_MASK: int = (
	InhibitFlags.LOGOUT | InhibitFlags.USER_SWITCH | InhibitFlags.SUSPEND | InhibitFlags.IDLE
)

## [enum Capability] to portal interface name.
##
## Descriptive, not the mechanism: capability availability comes from the
## backend (see [method has_capability]), and a backend that is not a portal
## serves capabilities without any of these interfaces existing. Useful for
## diagnostics and for the Linux backend's own translation.
const INTERFACE_NAMES: Dictionary = {
	Capability.GAME_MODE: "org.freedesktop.portal.GameMode",
	Capability.INHIBIT: "org.freedesktop.portal.Inhibit",
	Capability.POWER_PROFILE_MONITOR: "org.freedesktop.portal.PowerProfileMonitor",
	Capability.OPEN_URI: "org.freedesktop.portal.OpenURI",
	Capability.NOTIFICATION: "org.freedesktop.portal.Notification",
}

## Minimum [code]org.freedesktop.portal.OpenURI[/code] version exposing
## [code]SchemeSupported[/code].
const SCHEME_SUPPORTED_MIN_VERSION: int = 5

const _PRIORITY_NAMES: PackedStringArray = ["low", "normal", "high", "urgent"]

var _backend: DesktopServicesBackend = null
var _capabilities: Dictionary = {}
var _interface_versions: Dictionary = {}


func _ready() -> void:
	# Autoloads keep running while the tree is paused; portal state changes are
	# still worth forwarding then.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_backend()


func _exit_tree() -> void:
	if _backend != null:
		_backend.shutdown()


# --- Backend management -------------------------------------------------------

## Replaces the active backend. Tests use this to inject an
## [DesktopServicesMockBackend]; the previous backend is shut down and disconnected.
func set_backend(backend: DesktopServicesBackend) -> void:
	if backend == null:
		push_error("DesktopServices.set_backend() requires a backend; use DesktopServicesNullBackend.new().")
		return

	if _backend != null:
		_disconnect_backend(_backend)
		_backend.shutdown()

	_backend = backend
	_connect_backend(_backend)
	refresh_capabilities()


## The backend currently in use, selecting the default one if needed.
func get_backend() -> DesktopServicesBackend:
	_ensure_backend()
	return _backend


## Short name of the active backend: "native", "null" or "mock".
func get_backend_name() -> String:
	_ensure_backend()
	return _backend.get_backend_name()


## Whether portal calls can be attempted at all on this machine.
func is_available() -> bool:
	# Every capability check funnels through here, so this is where the facade
	# guarantees a backend exists even if it is used before `_ready()` runs.
	_ensure_backend()
	return _backend.is_available()


## Explains why portals are unavailable. Empty when they are available.
func get_unavailable_reason() -> String:
	if is_available():
		return ""
	if _backend.has_method("get_unavailable_reason"):
		return String(_backend.call("get_unavailable_reason"))
	return "XDG Desktop Portals are not available on this platform."


# --- Capability discovery -----------------------------------------------------

## Re-reads capabilities, and any portal interface versions behind them, from
## the backend and emits [signal capabilities_changed].
func refresh_capabilities() -> void:
	_ensure_backend()
	_capabilities = _backend.get_capabilities()
	_interface_versions = {}
	for capability: int in Capability.values():
		_interface_versions[capability] = _backend.get_interface_version(capability)
	capabilities_changed.emit()


## Maps every [enum Capability] to whether it is usable right now.
func get_capabilities() -> Dictionary:
	var capabilities: Dictionary = {}
	for capability: int in Capability.values():
		capabilities[capability] = has_capability(capability)
	return capabilities


## Whether [param capability] can be used with the current backend.
func has_capability(capability: Capability) -> bool:
	if not is_available():
		return false
	return bool(_capabilities.get(capability, false))


## Version of the [b]portal interface[/b] behind [param capability], or
## [code]-1[/code] when there is none to report.
##
## This is portal-specific and is not how availability is decided — use
## [method has_capability] for that. A backend that is not a portal has no
## interface to version and answers [code]-1[/code] for everything while still
## serving the capabilities it does have.
func get_interface_version(capability: Capability) -> int:
	if not is_available():
		return -1
	return int(_interface_versions.get(capability, -1))


# --- org.freedesktop.portal.GameMode -----------------------------------------

## Queries whether [param pid] is registered with GameMode. [code]0[/code] means
## the current process. Returns [constant GameModeStatus.UNKNOWN] when the status
## could not be determined.
func query_game_mode(pid: int = 0) -> GameModeStatus:
	if not has_capability(Capability.GAME_MODE):
		return GameModeStatus.UNKNOWN
	var status: int = _backend.game_mode_query_status(_resolve_pid(pid))
	match status:
		GameModeStatus.NOT_REGISTERED, GameModeStatus.REGISTERED, GameModeStatus.REJECTED:
			return status as GameModeStatus
		_:
			return GameModeStatus.UNKNOWN


## Asks GameMode to apply its optimisations to [param pid] ([code]0[/code] for the
## current process). Returns [code]false[/code] when the request did not succeed.
func request_game_mode(pid: int = 0) -> bool:
	if not has_capability(Capability.GAME_MODE):
		return false
	return _backend.game_mode_register(_resolve_pid(pid)) == 0


## Releases a registration made with [method request_game_mode].
func release_game_mode(pid: int = 0) -> bool:
	if not has_capability(Capability.GAME_MODE):
		return false
	return _backend.game_mode_unregister(_resolve_pid(pid)) == 0


# --- org.freedesktop.portal.Inhibit ------------------------------------------

## Asks the session to suppress [param flags] (a mask of [enum InhibitFlags])
## while explaining why with [param reason].
##
## Returns the request handle to pass to [method close_request], or an empty
## string when the request could not be started. The inhibition stays active
## until the handle is closed or the application exits.
func inhibit(flags: int, reason: String, parent_window: String = "") -> String:
	if not has_capability(Capability.INHIBIT):
		return ""
	if flags <= 0 or (flags & ~INHIBIT_FLAGS_MASK) != 0:
		push_error("DesktopServices.inhibit() called with invalid flags: %d." % flags)
		portal_error.emit("Inhibit.Inhibit", "Invalid inhibit flags: %d." % flags)
		return ""
	return _backend.inhibit(flags, reason, parent_window)


## Mask of [enum InhibitFlags] bits [method inhibit] can ask the current backend
## for, or [code]0[/code] when inhibition is unavailable.
##
## Use it to find out what a platform can request before asking:
##
## [codeblock]
## var wanted := DesktopServices.InhibitFlags.IDLE | DesktopServices.InhibitFlags.SUSPEND
## if wanted & DesktopServices.get_supported_inhibit_flags() == wanted:
##     handle = DesktopServices.inhibit(wanted, "Cutscene")
## [/codeblock]
##
## This is a static property of the backend, not a report of what the session
## did: a desktop that quietly ignores a bit it advertises is indistinguishable
## from one that acts on it, because the portal returns a request handle and
## never says which bits it honoured. [method inhibit] is unchanged by this — it
## still forwards any valid mask, and the portal remains free to ignore parts of
## it.
func get_supported_inhibit_flags() -> int:
	if not has_capability(Capability.INHIBIT):
		return 0
	return _backend.get_supported_inhibit_flags()


## Closes a request handle returned by [method inhibit] or [method open_uri],
## cancelling it if it is still pending.
func close_request(handle: String) -> bool:
	if handle.is_empty() or not is_available():
		return false
	return _backend.close_request(handle)


# --- org.freedesktop.portal.PowerProfileMonitor ------------------------------

## Whether the desktop is in power-saver mode, or [code]null[/code] when the
## state is unknown. Changes are reported by [signal power_saver_changed].
func is_power_saver_enabled() -> Variant:
	if not has_capability(Capability.POWER_PROFILE_MONITOR):
		return null
	var state: int = _backend.power_saver_state()
	if state < 0:
		return null
	return state == 1


# --- org.freedesktop.portal.OpenURI ------------------------------------------

## Opens [param uri] in the user's preferred handler. Set [param ask] to force
## the "open with" chooser.
##
## Returns a request handle whose outcome arrives via [signal request_completed],
## or an empty string when the URI was rejected or the call could not be started.
## [code]file:[/code] URIs are always rejected, case-insensitively.
func open_uri(uri: String, ask: bool = false, parent_window: String = "") -> String:
	if not has_capability(Capability.OPEN_URI):
		return ""
	var scheme: String = _scheme_of(uri)
	if scheme.is_empty():
		portal_error.emit("OpenURI.OpenURI", "Malformed or missing URI scheme: %s." % uri)
		return ""
	if scheme == "file":
		portal_error.emit("OpenURI.OpenURI", "The file: scheme is not allowed.")
		return ""
	return _backend.open_uri(uri, ask, parent_window)


## Whether the portal can open [param scheme], or [code]null[/code] when the
## running portal is too old to answer (interface version below
## [constant SCHEME_SUPPORTED_MIN_VERSION]) or the scheme is malformed.
func is_scheme_supported(scheme: String) -> Variant:
	if not has_capability(Capability.OPEN_URI):
		return null
	if not _is_valid_scheme(scheme):
		return null
	if scheme.to_lower() == "file":
		# Rejected by this addon regardless of what the portal reports.
		return false
	if get_interface_version(Capability.OPEN_URI) < SCHEME_SUPPORTED_MIN_VERSION:
		return null
	var supported: int = _backend.scheme_supported(scheme.to_lower())
	if supported < 0:
		return null
	return supported == 1


# --- org.freedesktop.portal.Notification -------------------------------------

## Posts a notification under [param id]. Reusing an id replaces the previous
## notification. Actions the user activates arrive via
## [signal notification_action_invoked].
func add_notification(
	id: String,
	title: String,
	body: String = "",
	priority: NotificationPriority = NotificationPriority.NORMAL
) -> bool:
	if not has_capability(Capability.NOTIFICATION):
		return false
	if id.is_empty():
		push_error("DesktopServices.add_notification() requires a non-empty id.")
		return false
	return _backend.add_notification(id, title, body, _priority_name(priority))


## Withdraws the notification previously posted under [param id].
func remove_notification(id: String) -> bool:
	if not has_capability(Capability.NOTIFICATION):
		return false
	if id.is_empty():
		return false
	return _backend.remove_notification(id)


# --- Internals ----------------------------------------------------------------

## Selects the default backend on first use. The facade is usable before
## [method _ready] runs — an autoload may be reached from another autoload's
## [method Node._ready], and tests construct the node outside the tree.
func _ensure_backend() -> void:
	if _backend == null:
		set_backend(_create_default_backend())


func _create_default_backend() -> DesktopServicesBackend:
	if OS.has_feature("web"):
		return DesktopServicesNullBackend.new("Desktop services are unavailable in a web build.")

	if OS.get_name() == "macOS":
		# macOS backs one capability of the five; the rest report unavailable
		# through the same contract the null backend uses.
		var mac: DesktopServicesMacBackend = DesktopServicesMacBackend.create()
		if mac != null:
			return mac
		return DesktopServicesNullBackend.new(
			"The MacPowerMonitor extension is not loaded; build it or use a release archive."
		)

	if OS.get_name() != "Linux":
		return DesktopServicesNullBackend.new(
			"XDG Desktop Portals are only available on Linux; running on %s." % OS.get_name()
		)

	var native: DesktopServicesNativeBackend = DesktopServicesNativeBackend.create()
	if native == null:
		return DesktopServicesNullBackend.new(
			"The XdgPortalNative extension is not loaded; build it or use a release archive."
		)
	if not native.is_available():
		var reason: String = native.get_unavailable_reason()
		native.shutdown()
		if reason.is_empty():
			return DesktopServicesNullBackend.new("Could not reach the session bus.")
		return DesktopServicesNullBackend.new("Could not reach the session bus: %s" % reason)
	return native


func _connect_backend(backend: DesktopServicesBackend) -> void:
	backend.power_saver_changed.connect(_on_power_saver_changed)
	backend.request_completed.connect(_on_request_completed)
	backend.notification_action_invoked.connect(_on_notification_action_invoked)
	backend.portal_error.connect(_on_portal_error)


func _disconnect_backend(backend: DesktopServicesBackend) -> void:
	backend.power_saver_changed.disconnect(_on_power_saver_changed)
	backend.request_completed.disconnect(_on_request_completed)
	backend.notification_action_invoked.disconnect(_on_notification_action_invoked)
	backend.portal_error.disconnect(_on_portal_error)


func _on_power_saver_changed(enabled: bool) -> void:
	power_saver_changed.emit(enabled)


func _on_request_completed(handle: String, response: int, results: Dictionary) -> void:
	request_completed.emit(handle, response, results)


func _on_notification_action_invoked(id: String, action: String, parameters: Array) -> void:
	notification_action_invoked.emit(id, action, parameters)


func _on_portal_error(context: String, message: String) -> void:
	portal_error.emit(context, message)


func _resolve_pid(pid: int) -> int:
	return OS.get_process_id() if pid == 0 else pid


func _priority_name(priority: NotificationPriority) -> String:
	var index: int = clampi(int(priority), 0, _PRIORITY_NAMES.size() - 1)
	return _PRIORITY_NAMES[index]


## Returns the lowercase scheme of [param uri], or an empty string when the URI
## carries no syntactically valid scheme.
func _scheme_of(uri: String) -> String:
	var separator: int = uri.find(":")
	if separator <= 0:
		return ""
	var scheme: String = uri.substr(0, separator)
	if not _is_valid_scheme(scheme):
		return ""
	return scheme.to_lower()


## RFC 3986 scheme syntax: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ).
func _is_valid_scheme(scheme: String) -> bool:
	if scheme.is_empty():
		return false
	for index: int in scheme.length():
		var c: int = scheme.unicode_at(index)
		var alpha: bool = (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		var digit: bool = c >= 48 and c <= 57
		if index == 0:
			if not alpha:
				return false
		elif not alpha and not digit and c != 43 and c != 45 and c != 46:
			return false
	return true
