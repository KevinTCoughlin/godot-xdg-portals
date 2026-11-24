# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
extends DesktopServicesTestCase

## org.freedesktop.portal.Notification coverage.

const Facade := DesktopServicesTestCase.FACADE_SCRIPT


func test_add_notification_forwards_every_field() -> void:
	assert_true(
		portal.add_notification("save", "Saved", "Chapter 3", Facade.NotificationPriority.HIGH)
	)
	var args: Array = mock.calls_to("add_notification")[0]["args"]
	assert_eq(args[0], "save")
	assert_eq(args[1], "Saved")
	assert_eq(args[2], "Chapter 3")
	assert_eq(args[3], "high", "priorities are sent as the portal's string names")


func test_add_notification_defaults_to_normal_priority_and_empty_body() -> void:
	portal.add_notification("save", "Saved")
	var args: Array = mock.calls_to("add_notification")[0]["args"]
	assert_eq(args[2], "")
	assert_eq(args[3], "normal")
	assert_eq(args[4], "", "no default action unless one was asked for")
	assert_eq(args[5], [], "no buttons unless some were asked for")


func test_add_notification_forwards_a_default_action_and_buttons() -> void:
	var open := DesktopServicesNotificationButton.new("Open", "open")
	var dismiss := DesktopServicesNotificationButton.new("Dismiss", "dismiss")
	assert_true(
		portal.add_notification(
			"save", "Saved", "Chapter 3", Facade.NotificationPriority.HIGH, "open", [open, dismiss]
		)
	)
	var args: Array = mock.calls_to("add_notification")[0]["args"]
	assert_eq(args[3], "high")
	assert_eq(args[4], "open")
	assert_eq(args[5], [open, dismiss])


func test_add_notification_rejects_a_value_that_is_not_a_button() -> void:
	var open := DesktopServicesNotificationButton.new("Open", "open")
	assert_false(
		portal.add_notification(
			"save", "Saved", "", Facade.NotificationPriority.NORMAL, "", [open, "nope"]
		)
	)
	assert_eq(mock.calls.size(), 0, "a non-button never reaches the bus")


func test_add_notification_rejects_a_button_without_a_label() -> void:
	var errors := capture(portal, "portal_error")
	var button := DesktopServicesNotificationButton.new("", "open")
	assert_false(
		portal.add_notification(
			"save", "Saved", "", Facade.NotificationPriority.NORMAL, "", [button]
		)
	)
	assert_eq(mock.calls.size(), 0, "a rejected button never reaches the bus")
	assert_eq(errors.size(), 1)
	assert_eq(errors[0][0], "Notification.AddNotification")


func test_add_notification_rejects_duplicate_button_actions() -> void:
	var first := DesktopServicesNotificationButton.new("Open", "open")
	var second := DesktopServicesNotificationButton.new("Also open", "open")
	assert_false(
		portal.add_notification(
			"save", "Saved", "", Facade.NotificationPriority.NORMAL, "", [first, second]
		)
	)
	assert_eq(mock.calls.size(), 0)


func test_add_notification_rejects_a_control_character_in_an_action() -> void:
	var button := DesktopServicesNotificationButton.new("Open", "open\nfile")
	assert_false(
		portal.add_notification(
			"save", "Saved", "", Facade.NotificationPriority.NORMAL, "", [button]
		)
	)
	assert_false(
		portal.add_notification(
			"save", "Saved", "", Facade.NotificationPriority.NORMAL, "bad\naction"
		)
	)
	assert_eq(mock.calls.size(), 0)


func test_add_notification_rejects_an_overlong_action() -> void:
	var button := DesktopServicesNotificationButton.new("Open", "a".repeat(129))
	assert_false(
		portal.add_notification(
			"save", "Saved", "", Facade.NotificationPriority.NORMAL, "", [button]
		)
	)
	assert_eq(mock.calls.size(), 0)


func test_add_notification_rejects_too_many_buttons() -> void:
	var buttons: Array[DesktopServicesNotificationButton] = []
	for index: int in Facade.MAX_NOTIFICATION_BUTTONS + 1:
		buttons.append(
			DesktopServicesNotificationButton.new("Label %d" % index, "action-%d" % index)
		)
	assert_eq(buttons.size(), Facade.MAX_NOTIFICATION_BUTTONS + 1)
	assert_false(
		portal.add_notification(
			"save", "Saved", "", Facade.NotificationPriority.NORMAL, "", buttons
		)
	)
	assert_eq(mock.calls.size(), 0)


func test_every_priority_maps_to_its_portal_name() -> void:
	var expected := {
		Facade.NotificationPriority.LOW: "low",
		Facade.NotificationPriority.NORMAL: "normal",
		Facade.NotificationPriority.HIGH: "high",
		Facade.NotificationPriority.URGENT: "urgent",
	}
	for priority: int in expected:
		mock.clear_calls()
		portal.add_notification("id", "title", "", priority)
		assert_eq(mock.calls_to("add_notification")[0]["args"][3], expected[priority])


func test_add_notification_rejects_an_empty_id() -> void:
	var errors := capture(portal, "portal_error")
	assert_false(portal.add_notification("", "Saved"))
	assert_eq(mock.calls.size(), 0)
	assert_eq(errors.size(), 1)
	assert_eq(errors[0][0], "Notification.AddNotification")


func test_add_notification_reports_backend_failure() -> void:
	mock.next_notification_succeeds = false
	assert_false(
		portal.add_notification("save", "Saved"),
		"a failed AddNotification is never reported as posted"
	)


func test_remove_notification_forwards_the_id() -> void:
	assert_true(portal.remove_notification("save"))
	assert_eq(mock.calls_to("remove_notification")[0]["args"][0], "save")


func test_remove_notification_rejects_an_empty_id() -> void:
	assert_false(portal.remove_notification(""))
	assert_eq(mock.calls.size(), 0)


func test_action_invoked_is_forwarded() -> void:
	var emissions := capture(portal, "notification_action_invoked")
	mock.emit_action("save", "open-folder", ["slot-3"])
	assert_eq(emissions.size(), 1)
	assert_eq(emissions[0][0], "save")
	assert_eq(emissions[0][1], "open-folder")
	assert_eq(emissions[0][2], ["slot-3"])


func test_missing_capability_skips_the_backend() -> void:
	mock.capabilities[Facade.Capability.NOTIFICATION] = false
	portal.refresh_capabilities()
	assert_false(portal.add_notification("save", "Saved"))
	assert_false(portal.remove_notification("save"))
	assert_eq(mock.calls.size(), 0)
