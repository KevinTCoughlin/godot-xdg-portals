# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesBackend
class_name DesktopServicesNullBackend

## Backend used wherever desktop portals cannot exist: Windows, macOS, mobile,
## web, and Linux sessions without a reachable session bus.
##
## Every call is a well-behaved no-op that reports "unknown" or "failed" rather
## than pretending an unavailable operation succeeded. Nothing here can crash,
## so the addon stays importable on every platform Godot targets.

## Human-readable explanation of why portals are unavailable, surfaced in
## [code]DesktopServices.get_unavailable_reason()[/code].
var reason: String = "XDG Desktop Portals are not available on this platform."


func _init(p_reason: String = "") -> void:
	if not p_reason.is_empty():
		reason = p_reason


func get_backend_name() -> String:
	return "null"


## Explains why portals are unavailable, mirroring
## [method DesktopServicesNativeBackend.get_unavailable_reason] so the facade can ask
## either backend the same question.
func get_unavailable_reason() -> String:
	return reason


# Every capability is absent here, which is exactly the contract's default, so
# get_capabilities() and get_interface_version() are deliberately not overridden.
