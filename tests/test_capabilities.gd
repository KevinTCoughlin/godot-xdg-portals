# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesTestCase

## Capability and interface-version discovery, plus error forwarding.

const Facade := DesktopServicesTestCase.FACADE_SCRIPT


func test_all_capabilities_are_present_with_the_default_mock() -> void:
	var capabilities: Dictionary = portal.get_capabilities()
	assert_eq(capabilities.size(), Facade.INTERFACE_NAMES.size())
	for capability: int in capabilities:
		assert_true(capabilities[capability], "capability %d should be present" % capability)


func test_interface_versions_are_reported() -> void:
	assert_eq(portal.get_interface_version(Facade.Capability.OPEN_URI), 5)
	assert_eq(portal.get_interface_version(Facade.Capability.INHIBIT), 3)


func test_absent_interface_reports_version_minus_one() -> void:
	mock.interface_versions["org.freedesktop.portal.GameMode"] = -1
	portal.refresh_capabilities()
	assert_eq(portal.get_interface_version(Facade.Capability.GAME_MODE), -1)
	assert_false(portal.has_capability(Facade.Capability.GAME_MODE))
	assert_false(portal.get_capabilities()[Facade.Capability.GAME_MODE])


func test_unavailable_backend_reports_no_capabilities() -> void:
	mock.available = false
	portal.refresh_capabilities()
	assert_false(portal.is_available())
	for capability: int in Facade.INTERFACE_NAMES:
		assert_eq(portal.get_interface_version(capability), -1,
			"an unreachable portal exports nothing, whatever it last reported")


func test_refresh_capabilities_emits_the_signal() -> void:
	var emissions := capture(portal, "capabilities_changed")
	portal.refresh_capabilities()
	portal.refresh_capabilities()
	assert_eq(emissions.size(), 2)


func test_capabilities_track_backend_changes() -> void:
	mock.interface_versions["org.freedesktop.portal.Notification"] = -1
	portal.refresh_capabilities()
	assert_false(portal.has_capability(Facade.Capability.NOTIFICATION))
	mock.interface_versions["org.freedesktop.portal.Notification"] = 2
	portal.refresh_capabilities()
	assert_true(portal.has_capability(Facade.Capability.NOTIFICATION))


func test_available_backend_reports_no_unavailable_reason() -> void:
	assert_eq(portal.get_unavailable_reason(), "")


func test_portal_errors_are_forwarded() -> void:
	var errors := capture(portal, "portal_error")
	mock.emit_error("OpenURI.OpenURI", "org.freedesktop.DBus.Error.ServiceUnknown")
	assert_eq(errors.size(), 1)
	assert_eq(errors[0][0], "OpenURI.OpenURI")
	assert_eq(errors[0][1], "org.freedesktop.DBus.Error.ServiceUnknown")


func test_interface_name_mapping_is_complete() -> void:
	# Every declared capability must name a real portal interface, otherwise
	# discovery would silently report it as absent forever.
	for capability: int in Facade.Capability.values():
		assert_true(Facade.INTERFACE_NAMES.has(capability),
			"capability %d has no interface name" % capability)
		assert_true(String(Facade.INTERFACE_NAMES[capability]).begins_with("org.freedesktop.portal."))
