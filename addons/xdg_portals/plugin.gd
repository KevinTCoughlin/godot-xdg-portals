# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
@tool
extends EditorPlugin

## Installs and removes the [code]XDGPortal[/code] autoload.

const AUTOLOAD_NAME := "XDGPortal"
const AUTOLOAD_PATH := "res://addons/xdg_portals/xdg_portal.gd"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
