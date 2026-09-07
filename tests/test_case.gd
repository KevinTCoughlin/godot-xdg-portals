# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends RefCounted
class_name DesktopServicesTestCase

## Minimal assertion base class for the mock-backed suite.
##
## The suite deliberately avoids third-party test frameworks and anything
## time-dependent: every test builds a facade, injects an
## [DesktopServicesMockBackend], and asserts on recorded calls and emitted signals.

const FACADE_SCRIPT := preload("res://addons/xdg_portals/desktop_services.gd")

var failures: PackedStringArray = []

var portal: Node = null
var mock: DesktopServicesMockBackend = null


## Runs before every test method.
func before_each() -> void:
	mock = DesktopServicesMockBackend.new()
	portal = FACADE_SCRIPT.new()
	portal.set_backend(mock)


## Runs after every test method.
func after_each() -> void:
	if portal != null:
		portal.free()
		portal = null
	mock = null


func fail(message: String) -> void:
	failures.append(message)


func assert_true(value: bool, message: String = "") -> void:
	if not value:
		fail("expected true; %s" % _describe(message))


func assert_false(value: bool, message: String = "") -> void:
	if value:
		fail("expected false; %s" % _describe(message))


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	if not _values_equal(actual, expected):
		fail("expected %s, got %s; %s" % [_repr(expected), _repr(actual), _describe(message)])


func assert_ne(actual: Variant, unexpected: Variant, message: String = "") -> void:
	if _values_equal(actual, unexpected):
		fail("expected a value other than %s; %s" % [_repr(unexpected), _describe(message)])


func assert_null(value: Variant, message: String = "") -> void:
	if value != null:
		fail("expected null, got %s; %s" % [_repr(value), _describe(message)])


func assert_not_null(value: Variant, message: String = "") -> void:
	if value == null:
		fail("expected a non-null value; %s" % _describe(message))


## Records every emission of [param signal_name] on [param source] into an array
## of argument arrays.
func capture(source: Object, signal_name: String) -> Array:
	var recorded: Array = []
	var sink := SignalSink.new()
	sink.recorded = recorded
	source.connect(signal_name, sink.on_emitted)
	# The sink must outlive the connection, so the test case keeps a reference.
	_sinks.append(sink)
	return recorded


var _sinks: Array = []


func _values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	return a == b


func _repr(value: Variant) -> String:
	if value == null:
		return "<null>"
	return "%s(%s)" % [type_string(typeof(value)), value]


func _describe(message: String) -> String:
	return message if not message.is_empty() else "no detail"


## Helper object that appends each emission's arguments to a shared array.
class SignalSink:
	extends RefCounted

	var recorded: Array = []

	func on_emitted(
		a0: Variant = null, a1: Variant = null, a2: Variant = null, a3: Variant = null
	) -> void:
		var args: Array = [a0, a1, a2, a3]
		while args.size() > 0 and args[args.size() - 1] == null:
			args.pop_back()
		recorded.append(args)
