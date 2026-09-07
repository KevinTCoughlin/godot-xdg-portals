# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
@tool
extends EditorPlugin

## Installs and removes the [code]DesktopServices[/code] autoload.

const AUTOLOAD_NAME := "DesktopServices"
const AUTOLOAD_PATH := "res://addons/xdg_portals/desktop_services.gd"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
