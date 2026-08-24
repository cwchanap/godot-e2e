extends GdUnitE2ETestSuite


func test_missing_node_raw_command_writes_failure_artifacts() -> void:
	var options := E2ELaunchOptions.new()
	options.extra_godot_args = PackedStringArray(["--quiet"])
	var game := await launch_game(options)
	if game == null or is_failure():
		return

	var result: E2EResult = await game.send_command(
		"get_property",
		{"path": "/root/DefinitelyMissingNode", "property": "text"},
	)
	assert_bool(result.ok).is_false()
	assert_bool(is_failure()).is_false()

	# Raw commands intentionally do not fail the suite, so this explicit call
	# exercises the public negative-path artifact escape hatch while reachable.
	await capture_failure_artifacts(game)
	var artifact_directory := _artifact_directory("test_missing_node_raw_command_writes_failure_artifacts")
	assert_bool(FileAccess.file_exists(artifact_directory + "/screenshot.png")).is_true()
	assert_bool(FileAccess.file_exists(artifact_directory + "/scene_tree.json")).is_true()
	assert_bool(FileAccess.file_exists(artifact_directory + "/engine_logs.json")).is_true()

	await close_game(game)
	assert_bool(FileAccess.file_exists(artifact_directory + "/stdout.log")).is_true()
	assert_bool(FileAccess.file_exists(artifact_directory + "/stderr.log")).is_true()


func _artifact_directory(test_name: String) -> String:
	return ProjectSettings.globalize_path(
		"res://test_output/%s/%s" % [get_name(), test_name]
	)
