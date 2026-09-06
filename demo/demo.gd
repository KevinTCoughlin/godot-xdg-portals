# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends Control

## Interactive demo for every portal surface the addon exposes.
##
## It is also the quickest way to check a real desktop session: run the project
## and the log pane shows exactly what the running portal service answered.

@onready var _log: RichTextLabel = %Log
@onready var _status: Label = %Status

var _inhibit_handle: String = ""


func _ready() -> void:
	XDGPortal.capabilities_changed.connect(_refresh_status)
	XDGPortal.power_saver_changed.connect(_on_power_saver_changed)
	XDGPortal.request_completed.connect(_on_request_completed)
	XDGPortal.notification_action_invoked.connect(_on_action_invoked)
	XDGPortal.portal_error.connect(_on_portal_error)

	%QueryGameModeButton.pressed.connect(_on_query_game_mode)
	%RequestGameModeButton.pressed.connect(_on_request_game_mode)
	%ReleaseGameModeButton.pressed.connect(_on_release_game_mode)
	%InhibitButton.pressed.connect(_on_inhibit)
	%CloseInhibitButton.pressed.connect(_on_close_inhibit)
	%PowerSaverButton.pressed.connect(_on_power_saver)
	%OpenUriButton.pressed.connect(_on_open_uri)
	%SchemeButton.pressed.connect(_on_scheme_supported)
	%NotifyButton.pressed.connect(_on_notify)
	%RemoveNotifyButton.pressed.connect(_on_remove_notify)

	_refresh_status()


func _refresh_status() -> void:
	if not XDGPortal.is_available():
		_status.text = "Portals unavailable (%s backend): %s" % [
			XDGPortal.get_backend_name(), XDGPortal.get_unavailable_reason()
		]
		return

	var present: PackedStringArray = []
	for capability: int in XDGPortal.INTERFACE_NAMES:
		if XDGPortal.has_capability(capability):
			var interface_name: String = XDGPortal.INTERFACE_NAMES[capability]
			present.append("%s v%d" % [
				interface_name.get_slice(".", 3), XDGPortal.get_interface_version(capability)
			])
	_status.text = "Backend: %s — %s" % [
		XDGPortal.get_backend_name(),
		", ".join(present) if present.size() > 0 else "no portal interfaces exported"
	]


func _on_query_game_mode() -> void:
	var status: int = XDGPortal.query_game_mode()
	_write("GameMode status: %s" % _game_mode_name(status))


func _on_request_game_mode() -> void:
	_write("RegisterGame: %s" % ("ok" if XDGPortal.request_game_mode() else "failed"))


func _on_release_game_mode() -> void:
	_write("UnregisterGame: %s" % ("ok" if XDGPortal.release_game_mode() else "failed"))


func _on_inhibit() -> void:
	var flags: int = XDGPortal.InhibitFlags.IDLE | XDGPortal.InhibitFlags.SUSPEND
	_inhibit_handle = XDGPortal.inhibit(flags, "Demo cutscene")
	_write("Inhibit handle: %s" % (_inhibit_handle if not _inhibit_handle.is_empty() else "<none>"))


func _on_close_inhibit() -> void:
	if _inhibit_handle.is_empty():
		_write("No inhibition to close.")
		return
	_write("Close(%s): %s" % [
		_inhibit_handle, "ok" if XDGPortal.close_request(_inhibit_handle) else "failed"
	])
	_inhibit_handle = ""


func _on_power_saver() -> void:
	var enabled: Variant = XDGPortal.is_power_saver_enabled()
	_write("power-saver-enabled: %s" % ("unknown" if enabled == null else str(enabled)))


func _on_open_uri() -> void:
	var uri: String = %UriEdit.text
	var handle: String = XDGPortal.open_uri(uri, %AskCheck.button_pressed)
	_write("OpenURI(%s) handle: %s" % [uri, handle if not handle.is_empty() else "<rejected>"])


func _on_scheme_supported() -> void:
	var scheme: String = %SchemeEdit.text
	var supported: Variant = XDGPortal.is_scheme_supported(scheme)
	_write("SchemeSupported(%s): %s" % [scheme, "unknown" if supported == null else str(supported)])


func _on_notify() -> void:
	var ok: bool = XDGPortal.add_notification(
		"demo", "Godot XDG Portals", "Posted from the demo project.",
		XDGPortal.NotificationPriority.NORMAL
	)
	_write("AddNotification: %s" % ("ok" if ok else "failed"))


func _on_remove_notify() -> void:
	_write("RemoveNotification: %s" % ("ok" if XDGPortal.remove_notification("demo") else "failed"))


func _on_power_saver_changed(enabled: bool) -> void:
	_write("[signal] power_saver_changed: %s" % enabled)


func _on_request_completed(handle: String, response: int, results: Dictionary) -> void:
	_write("[signal] request_completed: %s -> %s %s" % [
		handle, _response_name(response), results
	])


func _on_action_invoked(id: String, action: String, parameters: Array) -> void:
	_write("[signal] notification_action_invoked: %s / %s %s" % [id, action, parameters])


func _on_portal_error(context: String, message: String) -> void:
	_write("[error] %s: %s" % [context, message])


func _write(line: String) -> void:
	_log.append_text("%s\n" % line)


func _game_mode_name(status: int) -> String:
	match status:
		XDGPortal.GameModeStatus.NOT_REGISTERED:
			return "not registered"
		XDGPortal.GameModeStatus.REGISTERED:
			return "registered"
		XDGPortal.GameModeStatus.REJECTED:
			return "rejected"
		_:
			return "unknown"


func _response_name(response: int) -> String:
	match response:
		XDGPortal.Response.SUCCESS:
			return "success"
		XDGPortal.Response.CANCELLED:
			return "cancelled"
		_:
			return "other"
