# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesTestCase

## DesktopServicesMacBackend adapter coverage.
##
## The macOS extension cannot be loaded on the platform this suite runs on, so
## these tests bind the adapter to a stub standing in for MacPowerMonitor —
## the same shape the real class exposes. That covers everything the adapter
## itself does: capability reporting, the tri-state read, and signal
## forwarding. Whether Low Power Mode is read correctly is a question only a
## Mac can answer, and it is a row in docs/native-testing.md.

const Facade := DesktopServicesTestCase.FACADE_SCRIPT


class FakeMonitor:
	extends RefCounted

	signal power_saver_changed(enabled: bool)

	var state: int = 0

	func power_saver_state() -> int:
		return state

	func emit_change(enabled: bool) -> void:
		state = 1 if enabled else 0
		power_saver_changed.emit(enabled)


func _bound_backend(fake: FakeMonitor) -> DesktopServicesMacBackend:
	var backend := DesktopServicesMacBackend.new()
	backend._bind(fake)
	return backend


func test_create_returns_null_without_the_extension() -> void:
	# This suite never runs on macOS, so the class is genuinely absent here.
	assert_null(DesktopServicesMacBackend.create(), "no extension means no backend")


func test_reports_only_the_power_capability() -> void:
	portal.set_backend(_bound_backend(FakeMonitor.new()))
	assert_true(portal.has_capability(Facade.Capability.POWER_PROFILE_MONITOR),
		"power-saver state is the one capability macOS backs")
	assert_false(portal.has_capability(Facade.Capability.GAME_MODE))
	assert_false(portal.has_capability(Facade.Capability.INHIBIT))
	assert_false(portal.has_capability(Facade.Capability.OPEN_URI))
	assert_false(portal.has_capability(Facade.Capability.NOTIFICATION))


func test_unbacked_capabilities_stay_honest() -> void:
	portal.set_backend(_bound_backend(FakeMonitor.new()))
	assert_eq(portal.query_game_mode(), Facade.GameModeStatus.UNKNOWN)
	assert_eq(portal.inhibit(Facade.InhibitFlags.IDLE, "Cutscene"), "",
		"an unavailable inhibit yields no handle")
	assert_eq(portal.get_supported_inhibit_flags(), 0, "nothing is requestable")
	assert_eq(portal.open_uri("https://godotengine.org"), "")
	assert_null(portal.is_scheme_supported("https"))
	assert_false(portal.add_notification("id", "title"))


func test_power_saver_state_is_forwarded() -> void:
	var fake := FakeMonitor.new()
	portal.set_backend(_bound_backend(fake))

	fake.state = 1
	assert_true(portal.is_power_saver_enabled(), "enabled is reported as true")
	fake.state = 0
	assert_false(portal.is_power_saver_enabled(), "disabled is reported as false")
	fake.state = -1
	assert_null(portal.is_power_saver_enabled(), "unknown stays null, never false")


func test_power_saver_changes_are_forwarded() -> void:
	var fake := FakeMonitor.new()
	portal.set_backend(_bound_backend(fake))
	var emissions := capture(portal, "power_saver_changed")

	fake.emit_change(true)
	assert_eq(emissions.size(), 1, "the change reaches the facade")
	assert_true(emissions[0][0], "carrying the new state")


func test_backend_name_and_availability() -> void:
	var backend := _bound_backend(FakeMonitor.new())
	portal.set_backend(backend)
	assert_eq(portal.get_backend_name(), "macos")
	assert_true(portal.is_available(), "a bound backend is available")

	backend.shutdown()
	assert_false(backend.is_available(), "a shut-down backend reports unavailable")
	assert_eq(backend.power_saver_state(), -1, "and stops claiming to know the state")
