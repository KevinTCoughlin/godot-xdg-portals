# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesTestCase

## org.freedesktop.portal.PowerProfileMonitor coverage.


func test_power_saver_enabled() -> void:
	mock.next_power_saver_state = 1
	assert_eq(portal.is_power_saver_enabled(), true)


func test_power_saver_disabled() -> void:
	mock.next_power_saver_state = 0
	assert_eq(portal.is_power_saver_enabled(), false)


func test_power_saver_unknown_is_null() -> void:
	mock.next_power_saver_state = -1
	assert_null(portal.is_power_saver_enabled(),
		"an unreadable property is null, not a guessed false")


func test_power_saver_changes_are_forwarded() -> void:
	var emissions := capture(portal, "power_saver_changed")
	mock.emit_power_saver(true)
	mock.emit_power_saver(false)
	assert_eq(emissions.size(), 2)
	assert_eq(emissions[0][0], true)
	assert_eq(emissions[1][0], false)
	assert_eq(portal.is_power_saver_enabled(), false, "the reported state follows the signal")


func test_missing_capability_is_null() -> void:
	mock.interface_versions["org.freedesktop.portal.PowerProfileMonitor"] = -1
	portal.refresh_capabilities()
	assert_null(portal.is_power_saver_enabled())
