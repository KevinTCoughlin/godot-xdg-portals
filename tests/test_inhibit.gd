# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesTestCase

## org.freedesktop.portal.Inhibit and org.freedesktop.portal.Request coverage.

const Facade := DesktopServicesTestCase.FACADE_SCRIPT


func test_inhibit_returns_a_handle_and_forwards_arguments() -> void:
	var handle: String = portal.inhibit(Facade.InhibitFlags.IDLE, "Cutscene", "wayland:xyz")
	assert_ne(handle, "", "a started request yields a handle")
	var args: Array = mock.calls_to("inhibit")[0]["args"]
	assert_eq(args[0], Facade.InhibitFlags.IDLE)
	assert_eq(args[1], "Cutscene")
	assert_eq(args[2], "wayland:xyz", "the parent window identifier is forwarded verbatim")


func test_inhibit_accepts_combined_flags() -> void:
	var flags: int = Facade.InhibitFlags.IDLE | Facade.InhibitFlags.SUSPEND
	assert_ne(portal.inhibit(flags, "Long load"), "")
	assert_eq(mock.calls_to("inhibit")[0]["args"][0], flags)


func test_inhibit_accepts_every_documented_flag() -> void:
	assert_eq(Facade.INHIBIT_FLAGS_MASK, 15, "logout|user switch|suspend|idle")
	assert_ne(portal.inhibit(Facade.INHIBIT_FLAGS_MASK, "Everything"), "")


func test_supported_flags_reports_the_backend_mask() -> void:
	assert_eq(portal.get_supported_inhibit_flags(), Facade.INHIBIT_FLAGS_MASK)


func test_supported_flags_reports_a_partial_backend() -> void:
	mock.next_supported_inhibit_flags = Facade.InhibitFlags.IDLE | Facade.InhibitFlags.SUSPEND
	var supported: int = portal.get_supported_inhibit_flags()
	assert_eq(supported & Facade.InhibitFlags.IDLE, Facade.InhibitFlags.IDLE)
	assert_eq(supported & Facade.InhibitFlags.LOGOUT, 0, "logout is not requestable here")


func test_supported_flags_is_zero_without_the_capability() -> void:
	mock.interface_versions["org.freedesktop.portal.Inhibit"] = -1
	portal.refresh_capabilities()
	assert_eq(portal.get_supported_inhibit_flags(), 0, "nothing is requestable")


func test_supported_flags_does_not_gate_inhibit() -> void:
	# The portal may ignore bits it advertises, and never reports which it
	# honoured, so a narrower mask here must not change what inhibit() forwards.
	mock.next_supported_inhibit_flags = Facade.InhibitFlags.IDLE
	assert_ne(portal.inhibit(Facade.INHIBIT_FLAGS_MASK, "Everything"), "")
	assert_eq(mock.calls_to("inhibit")[0]["args"][0], Facade.INHIBIT_FLAGS_MASK)


func test_inhibit_rejects_zero_flags() -> void:
	var errors := capture(portal, "portal_error")
	assert_eq(portal.inhibit(0, "Nothing"), "", "an empty mask inhibits nothing")
	assert_eq(errors.size(), 1, "the rejection is reported")
	assert_eq(mock.calls.size(), 0, "nothing reaches the backend")


func test_inhibit_rejects_out_of_range_flags() -> void:
	assert_eq(portal.inhibit(16, "Unknown bit"), "", "undocumented bits are refused")
	assert_eq(portal.inhibit(-4, "Negative"), "", "negative masks are refused")
	assert_eq(mock.calls.size(), 0)


func test_inhibit_returns_empty_handle_when_the_call_cannot_start() -> void:
	mock.next_request_succeeds = false
	assert_eq(portal.inhibit(Facade.InhibitFlags.SUSPEND, "Boss fight"), "",
		"a failed start is never reported as a live inhibition")


func test_missing_capability_skips_the_backend() -> void:
	mock.interface_versions["org.freedesktop.portal.Inhibit"] = -1
	portal.refresh_capabilities()
	assert_eq(portal.inhibit(Facade.InhibitFlags.IDLE, "Cutscene"), "")
	assert_eq(mock.calls.size(), 0)


func test_close_request_forwards_the_handle() -> void:
	var handle: String = portal.inhibit(Facade.InhibitFlags.IDLE, "Cutscene")
	assert_true(portal.close_request(handle))
	assert_eq(mock.calls_to("close_request")[0]["args"][0], handle)


func test_close_request_rejects_an_empty_handle() -> void:
	assert_false(portal.close_request(""), "there is nothing to close")
	assert_eq(mock.calls_to("close_request").size(), 0)


func test_close_request_reports_backend_failure() -> void:
	mock.next_close_succeeds = false
	assert_false(portal.close_request("/org/freedesktop/portal/desktop/request/x/y"))


func test_request_completed_is_forwarded_with_results() -> void:
	var emissions := capture(portal, "request_completed")
	var handle: String = portal.inhibit(Facade.InhibitFlags.IDLE, "Cutscene")
	mock.complete_request(handle, Facade.Response.SUCCESS, {"id": "1"})
	assert_eq(emissions.size(), 1)
	assert_eq(emissions[0][0], handle)
	assert_eq(emissions[0][1], Facade.Response.SUCCESS)
	assert_eq(emissions[0][2], {"id": "1"})


func test_cancelled_requests_are_forwarded_as_cancelled() -> void:
	var emissions := capture(portal, "request_completed")
	mock.complete_request("/handle", Facade.Response.CANCELLED)
	assert_eq(emissions[0][1], Facade.Response.CANCELLED,
		"a user-dismissed request is never reported as a success")
