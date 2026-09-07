# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends RefCounted
class_name XDGPortalBackend

## Backend contract used by the [code]XDGPortal[/code] facade.
##
## Every method has an honest default: unknown state is reported as [code]-1[/code],
## [code]false[/code] or an empty handle, never as a fabricated success. Concrete
## backends are [XDGPortalNullBackend], [XDGPortalMockBackend] and
## [XDGPortalNativeBackend].

## Emitted when the compositor reports a change to the power-saver state.
signal power_saver_changed(enabled: bool)

## Emitted when an interactive portal request finishes.
signal request_completed(handle: String, response: int, results: Dictionary)

## Emitted when the user activates an action on a posted notification.
signal notification_action_invoked(id: String, action: String, parameters: Array)

## Emitted when a portal call fails. [param context] is the D-Bus member that failed.
signal portal_error(context: String, message: String)

## Short identifier used for diagnostics, e.g. [code]"native"[/code].
func get_backend_name() -> String:
	return "abstract"

## Whether portal calls can be attempted at all.
func is_available() -> bool:
	return false

## Maps portal interface names to their exported version, or [code]-1[/code].
func get_interface_versions() -> Dictionary:
	return {}

## Returns an [code]XDGPortal.GameModeStatus[/code] value.
func game_mode_query_status(_pid: int) -> int:
	return -1

## Returns 0 on success and -1 on failure, matching the portal interface.
func game_mode_register(_pid: int) -> int:
	return -1

## Returns 0 on success and -1 on failure, matching the portal interface.
func game_mode_unregister(_pid: int) -> int:
	return -1

## Returns the request handle, or an empty string when nothing was started.
func inhibit(_flags: int, _reason: String, _parent_window: String) -> String:
	return ""

## Mask of the [code]XDGPortal.InhibitFlags[/code] bits this backend can ask for.
##
## This declares what is *requestable*, not what a session actually did with the
## request: the portal answers [code]Inhibit[/code] with a request handle and
## never enumerates the bits it acted on, so a compositor that ignores one is
## indistinguishable from one that honours it. A backend that cannot inhibit at
## all reports [code]0[/code].
func get_supported_inhibit_flags() -> int:
	return 0

## Closes a pending request handle.
func close_request(_handle: String) -> bool:
	return false

## -1 unknown, 0 disabled, 1 enabled.
func power_saver_state() -> int:
	return -1

## Returns the request handle, or an empty string when nothing was started.
func open_uri(_uri: String, _ask: bool, _parent_window: String) -> String:
	return ""

## -1 unknown, 0 unsupported, 1 supported.
func scheme_supported(_scheme: String) -> int:
	return -1

## [param priority] is one of "low", "normal", "high" or "urgent".
func add_notification(_id: String, _title: String, _body: String, _priority: String) -> bool:
	return false

func remove_notification(_id: String) -> bool:
	return false

## Releases any native resources held by the backend.
func shutdown() -> void:
	pass
