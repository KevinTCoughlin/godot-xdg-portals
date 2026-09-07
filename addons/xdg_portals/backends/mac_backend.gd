# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesBackend
class_name DesktopServicesMacBackend

## Backend over the macOS [code]MacPowerMonitor[/code] GDExtension class.
##
## It implements exactly one capability — power-saver state — because that is
## the only one of the five with a genuine macOS equivalent. GameMode and
## OpenURI have nothing to call that the engine does not already do, inhibition
## cannot express two of its four flags, and notifications would impose
## packaging requirements on the consuming game. See
## [url=../../docs/roadmap.md]the roadmap[/url]. Every other call inherits the
## contract's honest default, exactly as the null backend does.

## Source of the [code]Capability[/code] values, so this cannot drift from the
## facade's enum.
const _FACADE := preload("res://addons/xdg_portals/desktop_services.gd")

var _native: RefCounted = null


## Returns a ready backend, or [code]null[/code] when the native class is not
## registered — which is every platform except macOS.
static func create() -> DesktopServicesMacBackend:
	if not ClassDB.class_exists(&"MacPowerMonitor"):
		return null
	if not ClassDB.can_instantiate(&"MacPowerMonitor"):
		return null

	var native: Object = ClassDB.instantiate(&"MacPowerMonitor")
	if native == null or not (native is RefCounted):
		return null

	var backend := DesktopServicesMacBackend.new()
	backend._bind(native as RefCounted)
	return backend


func _bind(native: RefCounted) -> void:
	_native = native
	_native.connect("power_saver_changed", _on_power_saver_changed)


func get_backend_name() -> String:
	return "macos"


func is_available() -> bool:
	return _native != null


## Explains the four capabilities this backend does not implement, so
## [code]get_unavailable_reason()[/code] is useful rather than empty on a
## platform where the backend itself is present.
func get_unavailable_reason() -> String:
	if _native == null:
		return "The MacPowerMonitor extension is not loaded."
	return ""


## Power-saver state, and nothing else. The four capabilities this backend
## cannot serve are simply absent, which the contract already reads as
## unavailable. There is no portal here and none is claimed:
## [method get_interface_version] inherits [code]-1[/code].
func get_capabilities() -> Dictionary:
	if _native == null:
		return {}
	return {_FACADE.Capability.POWER_PROFILE_MONITOR: true}


func power_saver_state() -> int:
	if _native == null:
		return -1
	return int(_native.call("power_saver_state"))


func shutdown() -> void:
	if _native != null:
		_native = null


func _on_power_saver_changed(enabled: bool) -> void:
	power_saver_changed.emit(enabled)
