# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesTestCase

## org.freedesktop.portal.GameMode coverage.

const Facade := DesktopServicesTestCase.FACADE_SCRIPT


func test_query_reports_registered() -> void:
	mock.next_game_mode_status = Facade.GameModeStatus.REGISTERED
	assert_eq(portal.query_game_mode(), Facade.GameModeStatus.REGISTERED)


func test_query_reports_active_for_others() -> void:
	mock.next_game_mode_status = Facade.GameModeStatus.ACTIVE_FOR_OTHERS
	assert_eq(portal.query_game_mode(), Facade.GameModeStatus.ACTIVE_FOR_OTHERS)


func test_query_never_reports_the_deprecated_rejected_status() -> void:
	mock.next_game_mode_status = Facade.GameModeStatus.REJECTED
	assert_eq(
		portal.query_game_mode(),
		Facade.GameModeStatus.UNKNOWN,
		"GameMode has no rejected state; a backend claiming one is not believed"
	)


func test_existing_enum_values_are_unchanged() -> void:
	assert_eq(Facade.GameModeStatus.UNKNOWN, -1)
	assert_eq(Facade.GameModeStatus.NOT_REGISTERED, 0)
	assert_eq(Facade.GameModeStatus.REGISTERED, 1)
	assert_eq(Facade.GameModeStatus.REJECTED, 2)


func test_native_backend_translates_portal_codes() -> void:
	# org.freedesktop.portal.GameMode.QueryStatus: 0 inactive, 1 active,
	# 2 active and registered by this pid, -1 failed.
	var translate := DesktopServicesNativeBackend.game_mode_status_from_portal
	assert_eq(translate.call(0), Facade.GameModeStatus.NOT_REGISTERED, "0 is inactive")
	assert_eq(
		translate.call(1),
		Facade.GameModeStatus.ACTIVE_FOR_OTHERS,
		"1 is active for someone else, not registered"
	)
	assert_eq(translate.call(2), Facade.GameModeStatus.REGISTERED, "2 is registered")
	assert_eq(translate.call(-1), Facade.GameModeStatus.UNKNOWN, "-1 is a failed query")
	assert_eq(translate.call(3), Facade.GameModeStatus.UNKNOWN, "undocumented codes are unknown")


func test_query_maps_unrecognised_status_to_unknown() -> void:
	mock.next_game_mode_status = 42
	assert_eq(
		portal.query_game_mode(),
		Facade.GameModeStatus.UNKNOWN,
		"an out-of-range status must not leak through as a valid value"
	)


func test_query_defaults_to_the_current_process() -> void:
	portal.query_game_mode()
	var calls := mock.calls_to("game_mode_query_status")
	assert_eq(calls.size(), 1)
	assert_eq(calls[0]["args"][0], OS.get_process_id(), "pid 0 means this process")


func test_query_forwards_an_explicit_pid() -> void:
	portal.query_game_mode(4242)
	assert_eq(mock.calls_to("game_mode_query_status")[0]["args"][0], 4242)


func test_request_succeeds_on_zero() -> void:
	mock.next_game_mode_result = 0
	assert_true(portal.request_game_mode(), "0 is the GameMode success code")
	assert_eq(mock.calls_to("game_mode_register").size(), 1)


func test_request_fails_on_negative_result() -> void:
	mock.next_game_mode_result = -1
	assert_false(portal.request_game_mode(), "-1 is the GameMode failure code")


func test_release_forwards_and_reports_success() -> void:
	mock.next_game_mode_result = 0
	assert_true(portal.release_game_mode(99))
	assert_eq(mock.calls_to("game_mode_unregister")[0]["args"][0], 99)


func test_release_fails_on_negative_result() -> void:
	mock.next_game_mode_result = -1
	assert_false(portal.release_game_mode())


func test_missing_capability_short_circuits_every_call() -> void:
	mock.capabilities[Facade.Capability.GAME_MODE] = false
	portal.refresh_capabilities()
	assert_eq(portal.query_game_mode(), Facade.GameModeStatus.UNKNOWN)
	assert_false(portal.request_game_mode())
	assert_false(portal.release_game_mode())
	assert_eq(mock.calls.size(), 0, "no bus traffic when the interface is absent")


func test_swapping_backends_releases_held_game_mode() -> void:
	assert_true(portal.request_game_mode())
	var held_by: DesktopServicesMockBackend = mock
	portal.set_backend(DesktopServicesMockBackend.new())
	var releases := held_by.calls_to("game_mode_unregister")
	assert_eq(releases.size(), 1, "the old backend's registration is released before it goes")
	if releases.size() == 1:
		assert_eq(releases[0]["args"][0], OS.get_process_id())


func test_released_game_mode_is_not_released_again() -> void:
	assert_true(portal.request_game_mode())
	assert_true(portal.release_game_mode())
	portal.set_backend(DesktopServicesMockBackend.new())
	assert_eq(mock.calls_to("game_mode_unregister").size(), 1, "only the explicit release")


func test_failed_registration_is_not_released() -> void:
	mock.next_game_mode_result = -1
	assert_false(portal.request_game_mode())
	portal.set_backend(DesktopServicesMockBackend.new())
	assert_eq(mock.calls_to("game_mode_unregister").size(), 0, "nothing was held")


func test_leaving_the_tree_releases_held_game_mode() -> void:
	assert_true(portal.request_game_mode(4242))
	# What the engine calls when the autoload leaves the tree at exit. The
	# runner's tree is not live while tests run, so it is called directly.
	portal._exit_tree()
	var releases := mock.calls_to("game_mode_unregister")
	assert_eq(releases.size(), 1, "an autoload leaving the tree releases GameMode")
	if releases.size() == 1:
		assert_eq(releases[0]["args"][0], 4242, "for the pid that was registered")
