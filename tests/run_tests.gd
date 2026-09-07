# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends SceneTree

## Deterministic, mock-backed test runner.
##
## Run it with:
## [codeblock]
## godot --headless --path . --script res://tests/run_tests.gd
## [/codeblock]
## The process exits with 0 when every test passes and 1 otherwise. Nothing here
## touches D-Bus, so the suite behaves identically on a developer desktop and on
## a headless CI runner.

const SUITES: Array[String] = [
	"res://tests/test_backend_selection.gd",
	"res://tests/test_capabilities.gd",
	"res://tests/test_game_mode.gd",
	"res://tests/test_inhibit.gd",
	"res://tests/test_mac_backend.gd",
	"res://tests/test_notification.gd",
	"res://tests/test_open_uri.gd",
	"res://tests/test_power_profile.gd",
]


func _initialize() -> void:
	var passed: int = 0
	var failed: int = 0
	var failure_log: PackedStringArray = []

	for suite_path: String in SUITES:
		var suite_script: GDScript = load(suite_path)
		if suite_script == null:
			failed += 1
			failure_log.append("%s: could not be loaded" % suite_path)
			continue

		var suite_name: String = suite_path.get_file().get_basename()
		for method_name: String in _test_methods(suite_script):
			var test: XDGPortalTestCase = suite_script.new()
			test.before_each()
			test.call(method_name)
			test.after_each()

			if test.failures.is_empty():
				passed += 1
				print("  ok   %s.%s" % [suite_name, method_name])
			else:
				failed += 1
				print("  FAIL %s.%s" % [suite_name, method_name])
				for failure: String in test.failures:
					failure_log.append("%s.%s: %s" % [suite_name, method_name, failure])
					print("       %s" % failure)

	print("")
	if failed > 0:
		print("Failures:")
		for entry: String in failure_log:
			print("  - %s" % entry)
		print("")
	print("%d passed, %d failed, %d total" % [passed, failed, passed + failed])

	quit(1 if failed > 0 else 0)


func _test_methods(suite_script: GDScript) -> PackedStringArray:
	var names: PackedStringArray = []
	for method: Dictionary in suite_script.get_script_method_list():
		var method_name: String = method["name"]
		if method_name.begins_with("test_") and not names.has(method_name):
			names.append(method_name)
	names.sort()
	return names
