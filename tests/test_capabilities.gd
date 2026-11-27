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
	mock.capabilities[Facade.Capability.GAME_MODE] = false
	portal.refresh_capabilities()
	assert_eq(portal.get_interface_version(Facade.Capability.GAME_MODE), -1)
	assert_false(portal.has_capability(Facade.Capability.GAME_MODE))
	assert_false(portal.get_capabilities()[Facade.Capability.GAME_MODE])


func test_unavailable_backend_reports_no_capabilities() -> void:
	mock.available = false
	portal.refresh_capabilities()
	assert_false(portal.is_available())
	for capability: int in Facade.Capability.values():
		assert_false(
			portal.has_capability(capability),
			"an unreachable backend serves nothing, whatever it last reported"
		)
		assert_eq(
			portal.get_interface_version(capability),
			-1,
			"and has no interface version to report either"
		)


func test_refresh_capabilities_emits_the_signal() -> void:
	var emissions := capture(portal, "capabilities_changed")
	portal.refresh_capabilities()
	portal.refresh_capabilities()
	assert_eq(emissions.size(), 2)


func test_capabilities_track_backend_changes() -> void:
	mock.capabilities[Facade.Capability.NOTIFICATION] = false
	portal.refresh_capabilities()
	assert_false(portal.has_capability(Facade.Capability.NOTIFICATION))
	mock.capabilities[Facade.Capability.NOTIFICATION] = true
	portal.refresh_capabilities()
	assert_true(portal.has_capability(Facade.Capability.NOTIFICATION))


func test_available_backend_reports_no_unavailable_reason() -> void:
	assert_eq(portal.get_unavailable_reason(), "")


func test_portal_return_refreshes_capabilities() -> void:
	mock.capabilities[Facade.Capability.OPEN_URI] = false
	mock.emit_portal_presence(true)
	assert_false(portal.has_capability(Facade.Capability.OPEN_URI))
	mock.capabilities[Facade.Capability.OPEN_URI] = true
	var emissions := capture(portal, "capabilities_changed")
	mock.emit_portal_presence(true)
	assert_true(portal.has_capability(Facade.Capability.OPEN_URI))
	assert_eq(portal.get_interface_version(Facade.Capability.OPEN_URI), 5)
	assert_eq(emissions.size(), 1, "a new portal owner refreshes capabilities")


func test_portal_disappearance_drops_capabilities_without_probing() -> void:
	# A probe would observe this version. Disappearance must not look.
	mock.interface_versions[Facade.Capability.OPEN_URI] = 1
	var emissions := capture(portal, "capabilities_changed")
	mock.emit_portal_presence(false)
	assert_eq(emissions.size(), 1, "losing the name reports the drop")
	assert_false(portal.has_capability(Facade.Capability.OPEN_URI))
	assert_false(portal.has_capability(Facade.Capability.GAME_MODE))
	assert_null(portal.is_power_saver_enabled(), "unknown while the name is unowned")
	assert_eq(
		portal.get_interface_version(Facade.Capability.OPEN_URI),
		-1,
		"the cache is dropped rather than re-read from the unowned name"
	)
	assert_eq(portal.open_uri("https://example.com"), "")
	assert_eq(portal.inhibit(Facade.InhibitFlags.IDLE, "Cutscene"), "")
	assert_false(portal.add_notification("save", "Saved"))
	assert_false(portal.close_request("/org/freedesktop/portal/desktop/request/x/y"))
	assert_eq(mock.calls.size(), 0, "nothing reaches the bus while the name is unowned")
	mock.emit_portal_presence(false)
	assert_eq(emissions.size(), 1, "a repeated disappearance is not another change")
	mock.interface_versions[Facade.Capability.OPEN_URI] = 5
	mock.emit_portal_presence(true)
	assert_true(portal.has_capability(Facade.Capability.OPEN_URI))
	assert_eq(portal.get_interface_version(Facade.Capability.OPEN_URI), 5)
	assert_eq(emissions.size(), 2, "the new owner is probed")


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
		assert_true(
			Facade.INTERFACE_NAMES.has(capability),
			"capability %d has no interface name" % capability
		)
		assert_true(
			String(Facade.INTERFACE_NAMES[capability]).begins_with("org.freedesktop.portal.")
		)
