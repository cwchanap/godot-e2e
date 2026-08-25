extends Node
class_name GdUnitE2EBootstrapRunner

const Config = preload("../server/config.gd")
const AutomationServer = preload("../server/automation_server.gd")
const LogCapture = preload("../server/log_capture.gd")

var _log_capture = null


func _ready() -> void:
	if not Config.is_enabled():
		push_error("godot-e2e: missing --gdunit-e2e")
		get_tree().quit(2)
		return
	if not Config.is_valid():
		push_error("godot-e2e: %s" % Config.get_validation_error())
		get_tree().quit(2)
		return

	var target_scene := Config.get_target_scene()
	if target_scene.is_empty():
		push_error("godot-e2e: missing --gdunit-e2e-target-scene")
		get_tree().quit(2)
		return

	_log_capture = LogCapture.new()
	_log_capture.set_verbosity_str(Config.get_log_verbosity())
	OS.add_logger(_log_capture)

	var error := get_tree().change_scene_to_file(target_scene)
	if error != OK:
		push_error("godot-e2e: failed to load target scene '%s' (error %d)" % [target_scene, error])
		get_tree().quit(2)
		return

	await get_tree().scene_changed

	var server := AutomationServer.new()
	server.name = "GdUnitE2EAutomationServer"
	server.set_log_capture(_log_capture)
	get_tree().root.add_child(server)

	queue_free()
