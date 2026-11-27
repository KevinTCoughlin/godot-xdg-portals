# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesTestCase

## GameMode holds across a gamemoded restart. The daemon, not the portal,
## holds registrations, so a new daemon instance has to be given them again.


func test_daemon_restart_takes_the_hold_again() -> void:
	assert_true(portal.request_game_mode(4242))
	mock.clear_calls()
	mock.emit_game_mode_daemon_presence(false)
	assert_eq(mock.calls.size(), 0, "the daemon going away is not probed")
	mock.emit_game_mode_daemon_presence(true)
	var registrations := mock.calls_to("game_mode_register")
	assert_eq(registrations.size(), 1, "the new gamemoded gets the registration back")
	if registrations.size() == 1:
		assert_eq(registrations[0]["args"][0], 4242, "for the pid that was held")
	assert_true(portal.request_game_mode(4242), "the hold is taken again")
	assert_eq(mock.calls_to("game_mode_register").size(), 1, "and not registered twice")
	assert_true(portal.release_game_mode(4242))
	assert_eq(mock.calls_to("game_mode_unregister").size(), 1, "the new hold is released")


func test_daemon_restart_does_not_take_a_released_hold() -> void:
	assert_true(portal.request_game_mode())
	assert_true(portal.release_game_mode())
	mock.clear_calls()
	mock.emit_game_mode_daemon_presence(false)
	mock.emit_game_mode_daemon_presence(true)
	assert_eq(mock.calls.size(), 0, "nothing was held, so nothing is registered")


func test_release_while_the_daemon_is_gone_is_local() -> void:
	assert_true(portal.request_game_mode())
	mock.clear_calls()
	mock.emit_game_mode_daemon_presence(false)
	assert_true(portal.release_game_mode(), "gamemoded already dropped the hold")
	assert_eq(mock.calls.size(), 0, "UnregisterGame would start a daemon that never had the pid")
	assert_false(portal.release_game_mode(), "the hold is gone")
	mock.emit_game_mode_daemon_presence(true)
	assert_eq(mock.calls.size(), 0, "a released hold is not registered again")


func test_request_while_the_daemon_is_gone_registers_now() -> void:
	assert_true(portal.request_game_mode())
	mock.clear_calls()
	mock.emit_game_mode_daemon_presence(false)
	assert_true(portal.request_game_mode(), "the request goes to the bus, not the stale hold")
	assert_eq(mock.calls_to("game_mode_register").size(), 1)
	mock.emit_game_mode_daemon_presence(true)
	assert_eq(mock.calls_to("game_mode_register").size(), 1, "already registered with it")


func test_rejected_retake_is_dropped_and_reported() -> void:
	assert_true(portal.request_game_mode())
	mock.emit_game_mode_daemon_presence(false)
	mock.next_game_mode_result = -1
	var errors := capture(portal, "portal_error")
	mock.emit_game_mode_daemon_presence(true)
	assert_eq(errors.size(), 1, "the lost hold is reported")
	mock.clear_calls()
	assert_false(portal.release_game_mode(), "no hold is claimed after the rejection")
	assert_eq(mock.calls.size(), 0)


func test_daemon_restart_during_a_portal_gap_waits_for_the_portal() -> void:
	assert_true(portal.request_game_mode())
	mock.clear_calls()
	mock.emit_portal_presence(false)
	mock.emit_game_mode_daemon_presence(false)
	mock.emit_game_mode_daemon_presence(true)
	assert_eq(mock.calls.size(), 0, "the unowned portal name is not called")
	mock.emit_portal_presence(true)
	assert_eq(mock.calls_to("game_mode_register").size(), 1, "registered once the portal is back")


func test_exit_after_the_daemon_went_away_does_not_unregister() -> void:
	assert_true(portal.request_game_mode())
	mock.clear_calls()
	mock.emit_game_mode_daemon_presence(false)
	portal._exit_tree()
	assert_eq(mock.calls_to("game_mode_unregister").size(), 0, "gamemoded already dropped the pid")
