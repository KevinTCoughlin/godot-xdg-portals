# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesTestCase

## org.freedesktop.portal.GameMode coverage.

const Facade := DesktopServicesTestCase.FACADE_SCRIPT


func test_query_reports_registered() -> void:
	mock.next_game_mode_status = Facade.GameModeStatus.REGISTERED
	assert_eq(portal.query_game_mode(), Facade.GameModeStatus.REGISTERED)


func test_query_reports_rejected() -> void:
	mock.next_game_mode_status = Facade.GameModeStatus.REJECTED
	assert_eq(portal.query_game_mode(), Facade.GameModeStatus.REJECTED)


func test_query_maps_unrecognised_status_to_unknown() -> void:
	mock.next_game_mode_status = 42
	assert_eq(portal.query_game_mode(), Facade.GameModeStatus.UNKNOWN,
		"an out-of-range status must not leak through as a valid value")


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
	mock.interface_versions["org.freedesktop.portal.GameMode"] = -1
	portal.refresh_capabilities()
	assert_eq(portal.query_game_mode(), Facade.GameModeStatus.UNKNOWN)
	assert_false(portal.request_game_mode())
	assert_false(portal.release_game_mode())
	assert_eq(mock.calls.size(), 0, "no bus traffic when the interface is absent")
