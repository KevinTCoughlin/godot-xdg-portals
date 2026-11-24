# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
class_name DesktopServicesNotificationButton
extends RefCounted

## One button on a notification posted with [method DesktopServices.add_notification].
##
## [member label] is the text the user sees. [member action] is the token
## reported by [signal DesktopServices.notification_action_invoked] when they
## press the button. A button has no target value: a target would be an
## arbitrary D-Bus variant, and this addon does not build those.

var label: String = ""
var action: String = ""


func _init(p_label: String = "", p_action: String = "") -> void:
	label = p_label
	action = p_action
