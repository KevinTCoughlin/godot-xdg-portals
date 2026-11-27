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
##
## XDG_PORTALS_SMOKE_MODE names the fake portal's behaviour for this run; the
## harness starts the fixture to match. See scripts/run_native_smoke.sh.

const TIMEOUT_SECONDS := 15.0

## The bus connection must give up within this long against a bus that never
## answers: CONNECT_TIMEOUT_MS in src/portal_constants.h, plus slack for a
## loaded CI machine.
const WEDGED_BUS_LIMIT_MSEC := 8000

var _failures: PackedStringArray = []
var _portal: Node = null
var _backend: DesktopServicesBackend = null
var _mode: String = ""
## Set by [_on_capabilities_refreshed] during the restart pass.
var _saw_capability_refresh: bool = false


func _initialize() -> void:
	_mode = OS.get_environment("XDG_PORTALS_SMOKE_MODE")
	if _mode.is_empty():
		_mode = "default"
	print("native smoke mode: %s" % _mode)

	var watchdog: SceneTreeTimer = create_timer(TIMEOUT_SECONDS)
	watchdog.timeout.connect(_on_timeout)

	if not ClassDB.class_exists(&"XdgPortalNative"):
		_fail("the XdgPortalNative extension is not loaded")
		_finish()
		return

	if _mode == "wedged-bus":
		_check_wedged_bus()
		_finish()
		return

	_backend = DesktopServicesNativeBackend.create()
	if _backend == null or not _backend.is_available():
		_fail("the native backend could not reach the session bus")
		_finish()
		return

	_portal = load("res://addons/xdg_portals/desktop_services.gd").new()
	_portal.set_backend(_backend)

	match _mode:
		"default", "immediate":
			_check_discovery()
			_check_game_mode()
			_check_open_uri_validation()
			_check_notification_sync()
			_check_teardown_mid_request()
			await _check_async_paths()
		"slow-start":
			await _check_slow_start()
		"restart":
			await _check_restart()
		_:
			_fail("unknown smoke mode '%s'" % _mode)
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
	# registered by this one. The immediate pass starts with another game
	# holding GameMode.
	var before: int = (
		_portal.GameModeStatus.ACTIVE_FOR_OTHERS
		if _mode == "immediate"
		else _portal.GameModeStatus.NOT_REGISTERED
	)
	_expect(
		_portal.query_game_mode() == before,
		"before registering, GameMode reports %s, got %s" % [before, _portal.query_game_mode()]
	)
	_expect(_portal.request_game_mode(), "RegisterGame should succeed")
	_expect(
		_portal.query_game_mode() == _portal.GameModeStatus.REGISTERED,
		"after registering, this process is registered, got %s" % _portal.query_game_mode()
	)
	# The portal rejects a second RegisterGame for a pid it already knows. The
	# facade must still report success, and one release must drop the only hold.
	_expect(_portal.request_game_mode(), "a second request does not take a second hold")
	_expect(
		_portal.query_game_mode() == _portal.GameModeStatus.REGISTERED,
		"the process stays registered after the second request"
	)
	_expect(_portal.release_game_mode(), "UnregisterGame should succeed")
	_expect(
		_portal.query_game_mode() == before,
		"after releasing, GameMode is back to %s, got %s" % [before, _portal.query_game_mode()]
	)
	_expect(not _portal.release_game_mode(), "releasing a pid this facade does not hold fails")
	_expect(
		_portal.query_game_mode() == before,
		"that release did not change GameMode, got %s" % _portal.query_game_mode()
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


## Destroys a second extension instance while its OpenURI call is still in
## flight, so teardown has a cancelled reply to deliver. Under --sanitize this
## catches a use-after-free on that path. It cannot catch the reply never being
## delivered: GLib keeps the abandoned call reachable, so LeakSanitizer stays
## quiet. XDG_PORTALS_DEBUG=1 shows "Operation was cancelled" when it is.
func _check_teardown_mid_request() -> void:
	var doomed: DesktopServicesNativeBackend = DesktopServicesNativeBackend.create()
	if doomed == null or not doomed.is_available():
		_fail("a second native backend could not be created")
		return
	var handle: String = doomed.open_uri("https://godotengine.org", false, "")
	_expect(handle != "", "a request can be started on a backend about to be destroyed")
	# Drops the only reference: the extension tears down here, mid-request.
	doomed.shutdown()
	_expect(not doomed.is_available(), "a shut-down backend reports unavailable")


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
	var inhibit_results: Dictionary = inhibit_result[2]
	_expect(
		str(inhibit_results.get("session_handle", "")).ends_with("_actual"),
		"the results dictionary is forwarded, got %s" % [inhibit_results]
	)

	# A request the portal ended (response 2) with a results payload: the code
	# is forwarded as OTHER and each value keeps its type.
	var other_handle: String = _portal.inhibit(_portal.InhibitFlags.IDLE, "smoke-other")
	_expect(other_handle != "", "a second inhibit should return a handle")
	var other_result: Array = await _portal.request_completed
	_expect(other_result[0] == other_handle, "the response should arrive on its own handle")
	_expect(
		other_result[1] == _portal.Response.OTHER,
		"response 2 is reported as OTHER, got %s" % [other_result[1]]
	)
	var details: Dictionary = other_result[2]
	_expect_same(details.get("uris"), ["https://a.example/", "https://b.example/"], "as results")
	_expect_same(details.get("count"), 3, "u results")
	_expect_same(details.get("ratio"), 0.25, "d results")
	_expect_same(details.get("granted"), true, "b results")

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

	# The fake portal rejects this id unless the payload is exactly this
	# default action and these two buttons, with no target variant. The action
	# that comes back is the default action we sent, so a client that dropped
	# the field would not see "open".
	var buttons: Array[DesktopServicesNotificationButton] = [
		DesktopServicesNotificationButton.new("Open", "open"),
		DesktopServicesNotificationButton.new("Dismiss", "dismiss"),
	]
	var posted: bool = _portal.add_notification(
		"smoke-actions", "Title", "Body", _portal.NotificationPriority.HIGH, "open", buttons
	)
	_expect(posted, "AddNotification with a default action and buttons should succeed")
	if posted:
		var chosen: Array = await _action_for("smoke-actions")
		_expect(chosen[1] == "open", "the invoked action is the default action that was sent")

	# Container types: `ay` arrives as bytes, and a dictionary keyed by
	# integers keeps its keys.
	_portal.add_notification("smoke-types", "Title")
	var typed: Array = await _action_for("smoke-types")
	var parameters: Array = typed[2]
	_expect(parameters.size() == 3, "three typed parameters arrive, got %s" % [parameters])
	if parameters.size() == 3:
		_expect(
			parameters[1] is PackedByteArray and parameters[1] == PackedByteArray([1, 2, 255]),
			"ay converts to PackedByteArray, got %s" % type_string(typeof(parameters[1]))
		)
		_expect(
			parameters[2] is Dictionary and parameters[2] == {1: "one", 2: "two"},
			"a{us} converts to a Dictionary keyed by int, got %s" % [parameters[2]]
		)

	await _check_scalar_conversion()
	await _check_power_saver_transition()


## Every GVariant type a portal can send, through ActionInvoked's `av`
## parameters: each basic type at the edge of its range (a `t` above INT64_MAX
## is clamped, not wrapped), then the containers that are not byte arrays.
func _check_scalar_conversion() -> void:
	_portal.add_notification("smoke-scalars", "Title")
	var scalars: Array = await _action_for("smoke-scalars")
	var expected: Array = [
		"slot-3",
		true,
		255,
		-32768,
		65535,
		-2147483648,
		4294967295,
		-9223372036854775807 - 1,
		9223372036854775807,
		42,
		-1.5,
		"/org/example/Path",
		"a{sv}",
		"nested",
		["pair", 9],
		PackedByteArray(),
		["x", 2],
		{"k": 5},
		[],
	]
	var parameters: Array = scalars[2]
	_expect(
		parameters.size() == expected.size(),
		"%d parameters arrive, got %d: %s" % [expected.size(), parameters.size(), parameters]
	)
	for i in mini(parameters.size(), expected.size()):
		_expect_same(parameters[i], expected[i], "parameter %d" % i)


## Waits for the action on notification [param id], ignoring any other.
func _action_for(id: String) -> Array:
	while true:
		var action: Array = await _portal.notification_action_invoked
		if action[0] == id:
			return action
		print("  ...  ignoring an action for '%s'" % action[0])
	return []


## The fake service toggles power-saver every 300 ms, alternating a
## PropertiesChanged that carries the new value with one that only invalidates
## the property. Both have to move the cached state: a client that ignores
## invalidation keeps the first value, and later carried updates repeat it.
func _check_power_saver_transition() -> void:
	var initial: Variant = _portal.is_power_saver_enabled()
	_expect(initial != null, "the power-saver property should be readable")
	var distinct: Array = []
	var latest: Variant = initial
	for _attempt in range(8):
		# A single-argument signal yields that argument directly, not an array.
		latest = await _portal.power_saver_changed
		_expect(
			_portal.is_power_saver_enabled() == latest,
			(
				"the cached state should follow the notification, got %s"
				% [_portal.is_power_saver_enabled()]
			)
		)
		if distinct.is_empty() or distinct[distinct.size() - 1] != latest:
			distinct.append(latest)
		if distinct.size() >= 2:
			break
	_expect(
		distinct.size() >= 2,
		"a carried value and an invalidation both update power-saver state, saw %s" % [distinct]
	)


## The portal took longer than the client's timeout to answer its first
## property read. Change notifications must still be delivered, and the state
## must become known.
func _check_slow_start() -> void:
	var changed: bool = await _portal.power_saver_changed
	_expect(true, "power_saver_changed arrived despite the slow start")
	_portal.refresh_capabilities()
	_expect(
		_portal.has_capability(_portal.Capability.POWER_PROFILE_MONITOR),
		"the power profile monitor is discovered once the portal answers"
	)
	_expect(
		_portal.is_power_saver_enabled() == changed,
		"the cached state follows the notification, got %s" % [_portal.is_power_saver_enabled()]
	)


## The portal exits after answering OpenURI, without ever sending its
## Response, and a fresh instance takes its place.
func _check_restart() -> void:
	# Granted before the crash, so the restart has an inhibition to drop. A
	# caller that only saw the success would keep believing the session is
	# inhibited after the Request object died with the old portal.
	var inhibit_handle: String = _portal.inhibit(_portal.InhibitFlags.IDLE, "Held across restart")
	_expect(inhibit_handle != "", "inhibit should return a handle")
	var inhibit_ok: Array = await _portal.request_completed
	_expect(
		inhibit_ok[0] == inhibit_handle, "the inhibition is acknowledged on the caller's handle"
	)
	_expect(inhibit_ok[1] == _portal.Response.SUCCESS, "and the first instance grants it")

	_saw_capability_refresh = false
	_portal.capabilities_changed.connect(_on_capabilities_refreshed)

	var uri_handle: String = _portal.open_uri("https://godotengine.org")
	_expect(uri_handle != "", "open_uri should return a handle")
	var lost: Dictionary = {}
	for _completion in 2:
		var result: Array = await _portal.request_completed
		lost[result[0]] = result[1]
	_expect(
		int(lost.get(uri_handle, -1)) == _portal.Response.OTHER,
		"the pending request completes as OTHER when the portal goes away, got %s" % [lost]
	)
	_expect(
		int(lost.get(inhibit_handle, -1)) == _portal.Response.OTHER,
		"a held inhibition is reported as ended, got %s" % [lost]
	)
	if not _saw_capability_refresh:
		await _portal.capabilities_changed
	_expect(_saw_capability_refresh, "capabilities are refreshed when the new portal appears")
	_expect(
		_portal.get_interface_version(_portal.Capability.OPEN_URI) == 5,
		"the refreshed OpenURI version comes from the new instance"
	)

	# The restarted instance toggles power-saver like the first one did. Seeing
	# that proves the signal subscriptions followed the new owner.
	var changed: bool = await _portal.power_saver_changed
	_expect(true, "power_saver_changed arrives from the restarted portal")
	_expect(
		_portal.is_power_saver_enabled() == changed, "the cached state follows the new instance"
	)

	var handle: String = _portal.inhibit(_portal.InhibitFlags.IDLE, "After restart")
	_expect(handle != "", "inhibit works against the restarted portal")
	var inhibit_result: Array = await _portal.request_completed
	_expect(inhibit_result[0] == handle, "its completion uses the caller's handle")
	_expect(inhibit_result[1] == _portal.Response.SUCCESS, "and the new instance answers 0")
	_expect(_portal.close_request(handle), "Close reaches the restarted portal")


## The session bus address points at a socket that never answers. Creating the
## backend must give up in bounded time and say why.
##
## Only the extension sees that address: it is set in this process just before
## the backend is created and put back straight after, because Godot talks to
## the session bus itself, with no timeout, and would hang before the test ran.
func _check_wedged_bus() -> void:
	var wedged: String = OS.get_environment("XDG_PORTALS_SMOKE_WEDGED_BUS")
	if wedged.is_empty():
		_fail("XDG_PORTALS_SMOKE_WEDGED_BUS is not set; run this through run_native_smoke.sh")
		return
	var real_bus: String = OS.get_environment("DBUS_SESSION_BUS_ADDRESS")
	OS.set_environment("DBUS_SESSION_BUS_ADDRESS", wedged)
	var started: int = Time.get_ticks_msec()
	var backend: DesktopServicesNativeBackend = DesktopServicesNativeBackend.create()
	var elapsed: int = Time.get_ticks_msec() - started
	OS.set_environment("DBUS_SESSION_BUS_ADDRESS", real_bus)
	_expect(backend != null, "the backend is still constructed")
	_expect(
		elapsed < WEDGED_BUS_LIMIT_MSEC,
		"connecting gave up after %d ms (limit %d)" % [elapsed, WEDGED_BUS_LIMIT_MSEC]
	)
	if backend != null:
		_expect(not backend.is_available(), "a bus that never answers is unavailable")
		_expect(
			backend.get_unavailable_reason().containsn("timed out"),
			"the reason says the connection timed out: '%s'" % backend.get_unavailable_reason()
		)
		backend.shutdown()


## Equal in value and in type: 1 and 1.0, or 1 and true, are not the same.
func _expect_same(actual: Variant, expected: Variant, what: String) -> void:
	_expect(
		typeof(actual) == typeof(expected) and actual == expected,
		(
			"%s: expected %s %s, got %s %s"
			% [what, type_string(typeof(expected)), expected, type_string(typeof(actual)), actual]
		)
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("  ok   %s" % message)
	else:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
	print("  FAIL %s" % message)


func _on_capabilities_refreshed() -> void:
	_saw_capability_refresh = true


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
	print("native smoke (%s): %d failure(s)" % [_mode, _failures.size()])
	quit(1 if _failures.size() > 0 else 0)
