# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends SceneTree

## End-to-end check of the native backend against the scripted fake portal in
## tests/native/fake_portal.c.
##
## This is not part of the default suite: it needs a session bus and the fake
## portal running, which scripts/run_native_smoke.sh arranges. It covers the
## parts of the native layer that do not need a human — bus connection, handle
## prediction, synchronous calls, and the three asynchronous signal paths — and
## deliberately does not stand in for the desktop checks in
## docs/native-testing.md.

const TIMEOUT_SECONDS := 15.0

var _failures: PackedStringArray = []
var _portal: Node = null
var _backend: DesktopServicesBackend = null


func _initialize() -> void:
	var watchdog: SceneTreeTimer = create_timer(TIMEOUT_SECONDS)
	watchdog.timeout.connect(_on_timeout)

	if not ClassDB.class_exists(&"XdgPortalNative"):
		_fail("the XdgPortalNative extension is not loaded")
		_finish()
		return

	_backend = DesktopServicesNativeBackend.create()
	if _backend == null or not _backend.is_available():
		_fail("the native backend could not reach the session bus")
		_finish()
		return

	_portal = load("res://addons/xdg_portals/desktop_services.gd").new()
	_portal.set_backend(_backend)

	_check_discovery()
	_check_game_mode()
	_check_open_uri_validation()
	_check_notification_sync()
	await _check_async_paths()
	_finish()


func _check_discovery() -> void:
	_expect(_portal.get_backend_name() == "native", "the native backend should be selected")
	_expect(_portal.is_available(), "portals should be available against the fake service")
	_expect(
		_portal.get_interface_version(_portal.Capability.OPEN_URI) == 5,
		"OpenURI version should be read from the service"
	)
	_expect(
		_portal.get_interface_version(_portal.Capability.INHIBIT) == 3,
		"Inhibit version should be read from the service"
	)
	for capability: int in _portal.Capability.values():
		_expect(
			_portal.has_capability(capability),
			"capability %s should be discovered" % _portal.Capability.keys()[capability]
		)
		_expect(
			_portal.get_interface_version(capability) >= 0,
			"and the native backend should report a portal version for it"
		)
	# Exercised here rather than in the mock suite: this is the one path that
	# reads the mask through the real native backend.
	_expect(
		_portal.get_supported_inhibit_flags() == _portal.INHIBIT_FLAGS_MASK,
		(
			"the portal can request every documented inhibit bit, got %d"
			% _portal.get_supported_inhibit_flags()
		)
	)


func _check_game_mode() -> void:
	# QueryStatus: 0 inactive, 1 active for another process, 2 active and
	# registered by this one.
	var before: int = _portal.GameModeStatus.NOT_REGISTERED
	_expect(
		_portal.query_game_mode() == before,
		"before registering, GameMode reports %s, got %s" % [before, _portal.query_game_mode()]
	)
	_expect(_portal.request_game_mode(), "RegisterGame should succeed")
	_expect(
		_portal.query_game_mode() == _portal.GameModeStatus.REGISTERED,
		"after registering, this process is registered, got %s" % _portal.query_game_mode()
	)
	_expect(_portal.release_game_mode(), "UnregisterGame should succeed")
	_expect(
		_portal.query_game_mode() == before,
		"after releasing, GameMode is back to %s, got %s" % [before, _portal.query_game_mode()]
	)


func _check_open_uri_validation() -> void:
	_expect(_portal.is_scheme_supported("https") == true, "https should be supported")
	_expect(_portal.is_scheme_supported("ftp") == false, "ftp should be unsupported")
	_expect(_portal.is_scheme_supported("file") == false, "file: is always refused")
	_expect(_portal.open_uri("file:///etc/passwd") == "", "file: URIs never reach the bus")
	_expect(_portal.open_uri("FILE:///etc/passwd") == "", "file: is refused case-insensitively")


func _check_notification_sync() -> void:
	_expect(
		_portal.add_notification("smoke", "Title", "Body", _portal.NotificationPriority.HIGH),
		"AddNotification should succeed"
	)
	_expect(_portal.remove_notification("smoke"), "RemoveNotification should succeed")


func _check_async_paths() -> void:
	# Inhibit: the fake service deliberately returns a different object path.
	# Completion must retain the handle returned to the caller, while Close must
	# use the real path supplied by the service.
	var handle: String = _portal.inhibit(_portal.InhibitFlags.IDLE, "Smoke test")
	_expect(
		handle.begins_with("/org/freedesktop/portal/desktop/request/"),
		"inhibit should predict a request handle, got '%s'" % handle
	)
	var inhibit_result: Array = await _portal.request_completed
	_expect(inhibit_result[0] == handle, "completion should use the caller's handle")
	_expect(inhibit_result[1] == _portal.Response.SUCCESS, "the fake service answers 0")
	_expect(
		_portal.close_request(handle), "Close should resolve the caller's handle to the portal path"
	)

	# OpenURI: the fake service answers 1, proving the real response code is
	# forwarded rather than assumed to be a success.
	var uri_handle: String = _portal.open_uri("https://godotengine.org")
	_expect(uri_handle != "", "open_uri should return a handle")
	var uri_result: Array = await _portal.request_completed
	_expect(uri_result[0] == uri_handle, "the response should arrive on the OpenURI handle")
	_expect(uri_result[1] == _portal.Response.CANCELLED, "a cancelled request is reported as such")

	# Notification actions. The "smoke" notification posted earlier also gets
	# an action from the fake service, so match on the id rather than taking
	# the first emission.
	_portal.add_notification("smoke-action", "Title")
	var action: Array = await _action_for("smoke-action")
	_expect(action[0] == "smoke-action", "the action should name the notification")
	_expect(action[1] == "open-folder", "the action name should be forwarded")
	_expect(action[2] == ["slot-3"], "the action parameters should be converted")

	# The fake service toggles power-saver every 300 ms.
	var initial: Variant = _portal.is_power_saver_enabled()
	_expect(initial != null, "the power-saver property should be readable")
	# A transition may occur between the read and the await. Observe a few
	# signals so the test checks for an actual state change, not timer phase.
	# A single-argument signal yields that argument directly, not an array.
	var changed: bool = false
	for _attempt in range(4):
		changed = await _portal.power_saver_changed
		if changed != initial:
			break
	_expect(changed != initial, "the change notification should carry the new state")
	_expect(
		_portal.is_power_saver_enabled() == changed,
		"the cached state should follow the notification"
	)


## Waits for the action on notification [param id], ignoring any other.
func _action_for(id: String) -> Array:
	while true:
		var action: Array = await _portal.notification_action_invoked
		if action[0] == id:
			return action
		print("  ...  ignoring an action for '%s'" % action[0])
	return []


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("  ok   %s" % message)
	else:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
	print("  FAIL %s" % message)


func _on_timeout() -> void:
	_fail("timed out after %.0f seconds waiting for the fake portal" % TIMEOUT_SECONDS)
	_finish()


func _finish() -> void:
	if _portal != null:
		# `_finish()` can run from inside a signal callback, where the facade is
		# still locked; deferring the free avoids tearing it down mid-emission.
		_portal.call_deferred("free")
		_portal = null
	print("")
	print("native smoke: %d failure(s)" % _failures.size())
	quit(1 if _failures.size() > 0 else 0)
