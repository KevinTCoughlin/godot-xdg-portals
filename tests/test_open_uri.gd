# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends XDGPortalTestCase

## org.freedesktop.portal.OpenURI coverage, including scheme validation.

const Facade := XDGPortalTestCase.FACADE_SCRIPT


func test_open_uri_returns_a_handle_and_forwards_arguments() -> void:
	var handle: String = portal.open_uri("https://godotengine.org", true, "x11:1234")
	assert_ne(handle, "")
	var args: Array = mock.calls_to("open_uri")[0]["args"]
	assert_eq(args[0], "https://godotengine.org")
	assert_eq(args[1], true, "the ask flag is forwarded")
	assert_eq(args[2], "x11:1234")


func test_open_uri_defaults_to_not_asking() -> void:
	portal.open_uri("https://godotengine.org")
	assert_eq(mock.calls_to("open_uri")[0]["args"][1], false)


func test_open_uri_rejects_the_file_scheme() -> void:
	var errors := capture(portal, "portal_error")
	assert_eq(portal.open_uri("file:///etc/passwd"), "", "file: URIs are never opened")
	assert_eq(errors.size(), 1)
	assert_eq(mock.calls.size(), 0, "the rejected URI never reaches the bus")


func test_open_uri_rejects_the_file_scheme_case_insensitively() -> void:
	assert_eq(portal.open_uri("FILE:///etc/passwd"), "")
	assert_eq(portal.open_uri("FiLe:///etc/passwd"), "")
	assert_eq(mock.calls.size(), 0)


func test_open_uri_rejects_a_uri_without_a_scheme() -> void:
	assert_eq(portal.open_uri("godotengine.org"), "")
	assert_eq(portal.open_uri(":no-scheme"), "")
	assert_eq(portal.open_uri(""), "")
	assert_eq(mock.calls.size(), 0)


func test_open_uri_rejects_a_malformed_scheme() -> void:
	assert_eq(portal.open_uri("1http://example.com"), "", "a scheme must start with a letter")
	assert_eq(portal.open_uri("ht tp://example.com"), "", "a scheme may not contain spaces")
	assert_eq(mock.calls.size(), 0)


func test_open_uri_accepts_schemes_with_punctuation() -> void:
	assert_ne(portal.open_uri("web+steam://run/440"), "", "RFC 3986 allows + - . in schemes")


func test_open_uri_returns_empty_handle_when_the_call_cannot_start() -> void:
	mock.next_request_succeeds = false
	assert_eq(portal.open_uri("https://godotengine.org"), "")


func test_missing_capability_skips_the_backend() -> void:
	mock.interface_versions["org.freedesktop.portal.OpenURI"] = -1
	portal.refresh_capabilities()
	assert_eq(portal.open_uri("https://godotengine.org"), "")
	assert_null(portal.is_scheme_supported("https"))
	assert_eq(mock.calls.size(), 0)


func test_scheme_supported_reports_true_and_false() -> void:
	mock.next_scheme_supported = 1
	assert_eq(portal.is_scheme_supported("https"), true)
	mock.next_scheme_supported = 0
	assert_eq(portal.is_scheme_supported("mailto"), false)


func test_scheme_supported_is_unknown_below_interface_version_5() -> void:
	mock.interface_versions["org.freedesktop.portal.OpenURI"] = 4
	portal.refresh_capabilities()
	assert_null(portal.is_scheme_supported("https"),
		"SchemeSupported does not exist before version 5, so the answer is unknown")
	assert_eq(mock.calls_to("scheme_supported").size(), 0)


func test_scheme_supported_is_unknown_when_the_portal_cannot_answer() -> void:
	mock.next_scheme_supported = -1
	assert_null(portal.is_scheme_supported("https"))


func test_scheme_supported_rejects_the_file_scheme() -> void:
	assert_eq(portal.is_scheme_supported("file"), false,
		"the addon refuses file: whatever the portal reports")
	assert_eq(portal.is_scheme_supported("FILE"), false)
	assert_eq(mock.calls_to("scheme_supported").size(), 0)


func test_scheme_supported_is_unknown_for_a_malformed_scheme() -> void:
	assert_null(portal.is_scheme_supported(""))
	assert_null(portal.is_scheme_supported("1http"))
	assert_null(portal.is_scheme_supported("https://"))


func test_scheme_supported_normalises_case() -> void:
	portal.is_scheme_supported("HTTPS")
	assert_eq(mock.calls_to("scheme_supported")[0]["args"][0], "https")
