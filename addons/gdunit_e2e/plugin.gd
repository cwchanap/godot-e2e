@tool
extends EditorPlugin

## The autoload registration pattern is adapted from
## RandallLiuXin/godot-e2e@ae6219f6e758a0f29bd243c8f963417fe4d63c36
## under Apache-2.0, with the addon-specific name and path.

const AUTOLOAD_NAME := "GdUnitE2EAutomationServer"
const AUTOLOAD_PATH := "res://addons/gdunit_e2e/server/automation_server.gd"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	var setting := "autoload/%s" % AUTOLOAD_NAME
	if not ProjectSettings.has_setting(setting):
		return
	var value = ProjectSettings.get_setting(setting)
	if value == AUTOLOAD_PATH or value == "*" + AUTOLOAD_PATH:
		remove_autoload_singleton(AUTOLOAD_NAME)
