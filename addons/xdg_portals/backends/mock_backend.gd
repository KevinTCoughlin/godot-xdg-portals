# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends XDGPortalBackend
class_name XDGPortalMockBackend

## Fully scripted backend used by the test suite and by games that want to
## exercise portal code paths without a desktop session.
##
## Every call is recorded in [member calls] and answered from the public
## [code]next_*[/code] fields, so tests stay deterministic: no timers, no bus, no
## sleeping. Interactive requests are completed by calling
## [method complete_request] explicitly.
##
## [codeblock]
## var mock := XDGPortalMockBackend.new()
## mock.next_game_mode_status = XDGPortal.GameModeStatus.REGISTERED
## XDGPortal.set_backend(mock)
## [/codeblock]

## Source of the default flag mask; see [XDGPortalNativeBackend] for why this is
## preloaded rather than read off the autoload.
const _FACADE := preload("res://addons/xdg_portals/xdg_portal.gd")

## Ordered log of every backend call: [code]{"method": String, "args": Array}[/code].
var calls: Array[Dictionary] = []

## Whether the mock reports portals as reachable.
var available: bool = true

## Interface versions handed to the facade for capability discovery.
var interface_versions: Dictionary = {
	"org.freedesktop.portal.GameMode": 1,
	"org.freedesktop.portal.Inhibit": 3,
	"org.freedesktop.portal.PowerProfileMonitor": 1,
	"org.freedesktop.portal.OpenURI": 5,
	"org.freedesktop.portal.Notification": 2,
}

## Value returned by [method game_mode_query_status].
var next_game_mode_status: int = 0
## Value returned by [method game_mode_register] and [method game_mode_unregister].
var next_game_mode_result: int = 0
## Handle returned by [method inhibit] and [method open_uri]; a per-call counter
## is appended so handles are unique but predictable.
var next_handle_prefix: String = "/org/freedesktop/portal/desktop/request/mock/token"
## When false, interactive calls return an empty handle.
var next_request_succeeds: bool = true
## Value returned by [method close_request].
var next_close_succeeds: bool = true
## Mask returned by [method get_supported_inhibit_flags]. Defaults to every
## documented bit; set it lower to exercise a backend that can request less.
var next_supported_inhibit_flags: int = _FACADE.INHIBIT_FLAGS_MASK
## -1 unknown, 0 disabled, 1 enabled.
var next_power_saver_state: int = 0
## -1 unknown, 0 unsupported, 1 supported.
var next_scheme_supported: int = 1
## Value returned by the notification methods.
var next_notification_succeeds: bool = true

var _handle_counter: int = 0


func get_backend_name() -> String:
	return "mock"


func is_available() -> bool:
	return available


func get_interface_versions() -> Dictionary:
	return interface_versions.duplicate()


func game_mode_query_status(pid: int) -> int:
	_record("game_mode_query_status", [pid])
	return next_game_mode_status


func game_mode_register(pid: int) -> int:
	_record("game_mode_register", [pid])
	return next_game_mode_result


func game_mode_unregister(pid: int) -> int:
	_record("game_mode_unregister", [pid])
	return next_game_mode_result


func inhibit(flags: int, reason: String, parent_window: String) -> String:
	_record("inhibit", [flags, reason, parent_window])
	return _next_handle()


func close_request(handle: String) -> bool:
	_record("close_request", [handle])
	return next_close_succeeds


func get_supported_inhibit_flags() -> int:
	return next_supported_inhibit_flags


func power_saver_state() -> int:
	return next_power_saver_state


func open_uri(uri: String, ask: bool, parent_window: String) -> String:
	_record("open_uri", [uri, ask, parent_window])
	return _next_handle()


func scheme_supported(scheme: String) -> int:
	_record("scheme_supported", [scheme])
	return next_scheme_supported


func add_notification(id: String, title: String, body: String, priority: String) -> bool:
	_record("add_notification", [id, title, body, priority])
	return next_notification_succeeds


func remove_notification(id: String) -> bool:
	_record("remove_notification", [id])
	return next_notification_succeeds


# --- Test drivers -------------------------------------------------------------

## Emits [signal XDGPortalBackend.request_completed] as the portal would.
func complete_request(handle: String, response: int, results: Dictionary = {}) -> void:
	request_completed.emit(handle, response, results)


## Emits [signal XDGPortalBackend.power_saver_changed] and updates the cached state.
func emit_power_saver(enabled: bool) -> void:
	next_power_saver_state = 1 if enabled else 0
	power_saver_changed.emit(enabled)


## Emits [signal XDGPortalBackend.notification_action_invoked].
func emit_action(id: String, action: String, parameters: Array = []) -> void:
	notification_action_invoked.emit(id, action, parameters)


## Emits [signal XDGPortalBackend.portal_error].
func emit_error(context: String, message: String) -> void:
	portal_error.emit(context, message)


## Returns the recorded calls for [param method], in order.
func calls_to(method: String) -> Array[Dictionary]:
	var matches: Array[Dictionary] = []
	for call in calls:
		if call["method"] == method:
			matches.append(call)
	return matches


## Forgets every recorded call.
func clear_calls() -> void:
	calls.clear()


func _record(method: String, args: Array) -> void:
	calls.append({"method": method, "args": args})


func _next_handle() -> String:
	if not next_request_succeeds:
		return ""
	_handle_counter += 1
	return "%s%d" % [next_handle_prefix, _handle_counter]
