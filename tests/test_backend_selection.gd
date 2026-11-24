# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesTestCase

## Backend injection, the null backend contract, and default backend selection.


func test_injected_backend_is_active() -> void:
	assert_eq(portal.get_backend_name(), "mock", "the injected mock should be active")
	assert_true(portal.is_available(), "the mock reports portals as available")


func test_set_backend_emits_capabilities_changed() -> void:
	var emissions := capture(portal, "capabilities_changed")
	portal.set_backend(DesktopServicesMockBackend.new())
	assert_eq(emissions.size(), 1, "swapping a backend re-discovers capabilities")


func test_set_backend_rejects_null() -> void:
	# push_error() is expected here; the previous backend must survive.
	portal.set_backend(null)
	assert_eq(portal.get_backend_name(), "mock", "a null argument must not clear the backend")


func test_set_backend_disconnects_the_previous_backend() -> void:
	var previous := mock
	var emissions := capture(portal, "power_saver_changed")
	portal.set_backend(DesktopServicesMockBackend.new())
	previous.emit_power_saver(true)
	assert_eq(emissions.size(), 0, "signals from a replaced backend must not be forwarded")


func test_null_backend_reports_unavailable() -> void:
	portal.set_backend(DesktopServicesNullBackend.new("no session bus"))
	assert_false(portal.is_available(), "the null backend is never available")
	assert_eq(portal.get_unavailable_reason(), "no session bus", "the reason is surfaced verbatim")


func test_null_backend_reports_unknown_state_honestly() -> void:
	portal.set_backend(DesktopServicesNullBackend.new())
	assert_eq(
		portal.query_game_mode(), DesktopServicesTestCase.FACADE_SCRIPT.GameModeStatus.UNKNOWN
	)
	assert_null(portal.is_power_saver_enabled(), "unknown power state is null")
	assert_null(portal.is_scheme_supported("https"), "unknown scheme support is null")
	assert_eq(portal.inhibit(8, "reason"), "", "an unavailable inhibit yields no handle")
	assert_eq(
		portal.open_uri("https://godotengine.org"), "", "an unavailable open yields no handle"
	)
	assert_false(portal.request_game_mode(), "an unavailable operation is never a success")
	assert_false(portal.add_notification("id", "title"), "an unavailable notification fails")
	assert_false(portal.remove_notification("id"), "an unavailable removal fails")
	assert_false(portal.close_request("/some/handle"), "there is nothing to close")


func test_null_backend_reports_every_interface_as_absent() -> void:
	portal.set_backend(DesktopServicesNullBackend.new())
	for capability: int in DesktopServicesTestCase.FACADE_SCRIPT.INTERFACE_NAMES:
		assert_eq(portal.get_interface_version(capability), -1, "no interface is exported")
		assert_false(portal.has_capability(capability), "no capability is present")


func test_backend_is_selected_before_ready_runs() -> void:
	# Regression: the facade used to pick its backend only in `_ready()`, so an
	# autoload reached from another autoload's `_ready()` saw no backend at all
	# and reported the "none" backend instead of degrading to the null one.
	var standalone: Node = DesktopServicesTestCase.FACADE_SCRIPT.new()
	assert_ne(
		standalone.get_backend_name(),
		"none",
		"a facade outside the tree must still choose a backend"
	)
	assert_not_null(standalone.get_backend())
	standalone.free()


func test_null_backend_reason_reaches_the_facade() -> void:
	# Regression: the null backend carried its reason in a plain field the facade
	# never read, so every unavailable session reported the same generic text.
	var backend := DesktopServicesNullBackend.new("headless session, no D-Bus")
	assert_true(
		backend.has_method("get_unavailable_reason"),
		"the facade discovers the reason through this method"
	)
	portal.set_backend(backend)
	assert_eq(portal.get_unavailable_reason(), "headless session, no D-Bus")


func test_exit_tree_releases_and_disconnects() -> void:
	assert_true(portal.request_game_mode())
	var emissions := capture(portal, "power_saver_changed")
	portal._exit_tree()
	mock.emit_power_saver(true)
	assert_eq(emissions.size(), 0, "a shut-down backend must not forward signals")
	assert_eq(
		mock.calls_to("game_mode_unregister").size(), 1, "the hold is released on the way out"
	)
	assert_eq(mock.calls_to("shutdown").size(), 1, "the backend is shut down")
	assert_null(portal._backend, "the facade drops its reference")


func test_exit_tree_is_safe_to_call_twice() -> void:
	assert_true(portal.request_game_mode())
	portal._exit_tree()
	portal._exit_tree()
	assert_eq(mock.calls_to("game_mode_unregister").size(), 1, "the hold is released once")
	assert_eq(mock.calls_to("shutdown").size(), 1, "shutdown runs once")


func test_exit_tree_allows_a_new_backend() -> void:
	assert_true(portal.request_game_mode())
	portal._exit_tree()
	var replacement := DesktopServicesMockBackend.new()
	portal.set_backend(replacement)
	assert_true(portal.is_available(), "the replacement is the live backend")
	assert_true(portal.request_game_mode(), "calls work again after a reload")
	assert_eq(mock.calls_to("game_mode_register").size(), 1, "the old backend is not reused")
	assert_eq(replacement.calls_to("game_mode_register").size(), 1)


func test_reentering_the_tree_selects_a_fresh_backend() -> void:
	# The runner's tree is not live, so add/remove never emit these. Call them
	# in the order a reparent uses: exit, then enter. `_ready` does not run again.
	portal._exit_tree()
	assert_eq(mock.calls_to("shutdown").size(), 1)
	portal._enter_tree()
	var restored: Object = portal._backend
	assert_not_null(restored, "re-entry selects a backend without waiting for a call")
	assert_ne(restored, mock, "re-entry must not keep the shut-down backend")
	var selected: String = portal.get_backend_name()
	assert_true(
		selected == "null" or selected == "native" or selected == "macos",
		"re-entry selects a real backend, got %s" % selected
	)
	portal._exit_tree()


func test_default_backend_never_crashes() -> void:
	# Exercises the real selection path: on CI (headless, no session bus) this
	# must land on the null backend; on a desktop it may pick the native one.
	var standalone: Node = DesktopServicesTestCase.FACADE_SCRIPT.new()
	Engine.get_main_loop().root.add_child(standalone)
	var name: String = standalone.get_backend_name()
	assert_true(name == "null" or name == "native", "unexpected default backend: %s" % name)
	if name == "null":
		assert_false(standalone.is_available(), "the null backend is not available")
		assert_ne(standalone.get_unavailable_reason(), "", "an unavailable backend explains itself")
	Engine.get_main_loop().root.remove_child(standalone)
	standalone.free()
