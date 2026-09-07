# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends XDGPortalBackend
class_name XDGPortalNativeBackend

## Thin adapter over the [code]XdgPortalNative[/code] GDExtension class.
##
## It owns no portal logic of its own: it forwards calls, re-emits the native
## signals under the backend contract, and translates the facade's typed
## arguments into the plain values the extension expects. Construct it through
## [method create], which returns [code]null[/code] when the extension is not
## loaded rather than raising.

## Source of the flag values, so the mask below cannot drift from the enum the
## facade publishes. Preloaded rather than read off the autoload: backends are
## constructed directly by the test suite, where no autoload exists.
const _FACADE := preload("res://addons/xdg_portals/xdg_portal.gd")

var _native: RefCounted = null


## Returns a ready backend, or [code]null[/code] when the native class is missing
## or could not reach the session bus.
static func create() -> XDGPortalNativeBackend:
	if not ClassDB.class_exists(&"XdgPortalNative"):
		return null
	if not ClassDB.can_instantiate(&"XdgPortalNative"):
		return null

	var native: Object = ClassDB.instantiate(&"XdgPortalNative")
	if native == null or not (native is RefCounted):
		return null

	var backend := XDGPortalNativeBackend.new()
	backend._bind(native as RefCounted)
	return backend


func _bind(native: RefCounted) -> void:
	_native = native
	_native.connect("power_saver_changed", _on_power_saver_changed)
	_native.connect("request_completed", _on_request_completed)
	_native.connect("notification_action_invoked", _on_notification_action_invoked)
	_native.connect("portal_error", _on_portal_error)


func get_backend_name() -> String:
	return "native"


func is_available() -> bool:
	return _native != null and bool(_native.call("is_available"))


## Reason reported by the extension when the session bus could not be reached.
func get_unavailable_reason() -> String:
	if _native == null:
		return "The XdgPortalNative extension is not loaded."
	return String(_native.call("get_unavailable_reason"))


func get_interface_versions() -> Dictionary:
	if _native == null:
		return {}
	return _native.call("get_interface_versions")


func game_mode_query_status(pid: int) -> int:
	if _native == null:
		return -1
	return int(_native.call("game_mode_query_status", pid))


func game_mode_register(pid: int) -> int:
	if _native == null:
		return -1
	return int(_native.call("game_mode_register", pid))


func game_mode_unregister(pid: int) -> int:
	if _native == null:
		return -1
	return int(_native.call("game_mode_unregister", pid))


func inhibit(flags: int, reason: String, parent_window: String) -> String:
	if _native == null:
		return ""
	return String(_native.call("inhibit", flags, reason, parent_window))


## The portal accepts all four bits. Whether the desktop's backend acts on each
## one varies (wlroots compositors commonly ignore logout and user-switch), and
## the portal does not report which it honoured — see
## [method XDGPortalBackend.get_supported_inhibit_flags].
func get_supported_inhibit_flags() -> int:
	if _native == null:
		return 0
	return _FACADE.INHIBIT_FLAGS_MASK


func close_request(handle: String) -> bool:
	if _native == null:
		return false
	return bool(_native.call("close_request", handle))


func power_saver_state() -> int:
	if _native == null:
		return -1
	return int(_native.call("power_saver_state"))


func open_uri(uri: String, ask: bool, parent_window: String) -> String:
	if _native == null:
		return ""
	return String(_native.call("open_uri", uri, ask, parent_window))


func scheme_supported(scheme: String) -> int:
	if _native == null:
		return -1
	return int(_native.call("scheme_supported", scheme))


func add_notification(id: String, title: String, body: String, priority: String) -> bool:
	if _native == null:
		return false
	return bool(_native.call("add_notification", id, title, body, priority))


func remove_notification(id: String) -> bool:
	if _native == null:
		return false
	return bool(_native.call("remove_notification", id))


func shutdown() -> void:
	# Dropping the last reference tears down the worker thread and the private
	# bus connection in the extension's destructor.
	_native = null


func _on_power_saver_changed(enabled: bool) -> void:
	power_saver_changed.emit(enabled)


func _on_request_completed(handle: String, response: int, results: Dictionary) -> void:
	request_completed.emit(handle, response, results)


func _on_notification_action_invoked(id: String, action: String, parameters: Array) -> void:
	notification_action_invoked.emit(id, action, parameters)


func _on_portal_error(context: String, message: String) -> void:
	portal_error.emit(context, message)
