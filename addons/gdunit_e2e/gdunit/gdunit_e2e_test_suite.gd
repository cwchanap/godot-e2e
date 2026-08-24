class_name GdUnitE2ETestSuite
extends GdUnitTestSuite


var _tracked_games: Array = []
var _active_test_name := ""


func launch_game(options := E2ELaunchOptions.new()) -> GdUnitE2EGame:
	var process := E2EProcess.new(self)
	add_child(process)
	var record := {"game": null, "process": process}
	_tracked_games.append(record)

	var result: E2EResult = await process.launch(options)
	if not result.ok:
		# Keep the launch error as the primary GdUnit failure. Teardown is
		# deliberately best effort and must not hide that error.
		fail(result.message)
		await _close_and_finalize(record)
		return null

	var game := GdUnitE2EGame.new(process.get_client(), self)
	record["game"] = game
	return game


func close_game(game: GdUnitE2EGame) -> void:
	var record := _record_for_game(game)
	if record == null:
		return
	await _close_and_finalize(record)


func capture_failure_artifacts(game: GdUnitE2EGame) -> void:
	if not is_instance_valid(game):
		return
	var record := _record_for_game(game)
	if record == null:
		return

	var paths := _artifact_paths()
	@warning_ignore("return_value_discarded")
	DirAccess.make_dir_recursive_absolute(paths["directory"])

	# These captures are intentionally independent. A failed remote request or
	# unavailable log buffer must not prevent the other reachable artifacts.
	if game.has_method("screenshot"):
		await game.screenshot(paths["screenshot"])

	var scene_tree: Variant = {}
	if game.has_method("get_tree"):
		var captured_tree = await game.get_tree()
		if captured_tree is Dictionary:
			scene_tree = captured_tree
	_write_json_best_effort(paths["scene_tree"], scene_tree)

	var engine_logs: Variant = []
	var process = record.get("process", null)
	if is_instance_valid(process) and process.has_method("get_client"):
		var client = process.get_client()
		if is_instance_valid(client) and client.has_method("get_collected_logs"):
			var captured_logs = client.get_collected_logs()
			if captured_logs is Array:
				engine_logs = captured_logs
	_write_json_best_effort(paths["engine_logs"], engine_logs)


func before_test() -> void:
	# A previous hook may have failed before it reached after_test(). Reap any
	# records first so every test starts without an inherited child process.
	await _close_all_tracked_games()
	await super.before_test()


func after_test() -> void:
	var records := _tracked_games.duplicate()
	for record in records:
		var game = record.get("game", null)
		if is_failure() and is_instance_valid(game):
			await capture_failure_artifacts(game)
		await _close_and_finalize(record)
	await super.after_test()


func after() -> void:
	# Final safety net for a test hook that failed before after_test() could
	# finish. The child process remains tracked until it has been reaped.
	await _close_all_tracked_games()
	await super.after()


func _record_for_game(game) -> Variant:
	for record in _tracked_games:
		if record.get("game", null) == game:
			return record
	return null


func _close_all_tracked_games() -> void:
	var records := _tracked_games.duplicate()
	for record in records:
		await _close_and_finalize(record)


func _close_and_finalize(record: Dictionary) -> void:
	if record == null:
		return

	var process = record.get("process", null)
	if is_instance_valid(process):
		if process.has_method("close"):
			await process.close()
			# E2EProcess.close() is bounded and idempotent. A retry keeps a
			# transient failed confirmation from leaving a child tracked.
			if process.has_method("get_close_error") \
					and not str(process.get_close_error()).is_empty():
				await process.close()
			if process.has_method("get_close_error"):
				var close_error := str(process.get_close_error())
				if not close_error.is_empty():
					if not record.get("cleanup_failure_reported", false):
						fail("E2E child cleanup failed: %s" % close_error)
						record["cleanup_failure_reported"] = true
					return

		var paths := _artifact_paths()
		if process.has_method("get_stdout"):
			_write_text_best_effort(paths["stdout"], str(process.get_stdout()))
		if process.has_method("get_stderr"):
			_write_text_best_effort(paths["stderr"], str(process.get_stderr()))

		_remove_process(process)
	_tracked_games.erase(record)


func _remove_process(process) -> void:
	if not is_instance_valid(process) or not process is Node:
		return
	var parent = process.get_parent()
	if parent != null:
		parent.remove_child(process)
	process.queue_free()


func _artifact_paths() -> Dictionary:
	var suite_name := _safe_path_component(get_name(), "suite")
	var test_name := _safe_path_component(_current_test_name(), "test")
	var directory := ProjectSettings.globalize_path(
		"res://test_output/%s/%s" % [suite_name, test_name]
	)
	return {
		"directory": directory,
		"screenshot": directory + "/screenshot.png",
		"scene_tree": directory + "/scene_tree.json",
		"engine_logs": directory + "/engine_logs.json",
		"stdout": directory + "/stdout.log",
		"stderr": directory + "/stderr.log",
	}


func _current_test_name() -> String:
	return _active_test_name


func set_active_test_case(test_case: String) -> void:
	_active_test_name = test_case
	super.set_active_test_case(test_case)


func _safe_path_component(value: String, fallback: String) -> String:
	var normalized := value.strip_edges()
	if normalized.is_empty():
		return fallback
	return normalized.replace("..", "_") \
		.replace("/", "_") \
		.replace("\\", "_") \
		.replace(":", "_")


func _write_json_best_effort(path: String, value: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(value))
	file.close()


func _write_text_best_effort(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(value)
	file.close()
