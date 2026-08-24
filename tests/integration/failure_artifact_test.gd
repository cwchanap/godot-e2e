extends GdUnitE2ETestSuite


func test_missing_node_raw_command_writes_failure_artifacts() -> void:
	var test_name := "test_missing_node_raw_command_writes_failure_artifacts"
	var artifact_directory := _artifact_directory(test_name)
	_remove_artifact_directory(artifact_directory)
	assert_bool(DirAccess.dir_exists_absolute(artifact_directory)).is_false()

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
	assert_bool(FileAccess.file_exists(artifact_directory + "/screenshot.png")).is_true()
	assert_bool(FileAccess.file_exists(artifact_directory + "/scene_tree.json")).is_true()
	assert_bool(FileAccess.file_exists(artifact_directory + "/engine_logs.json")).is_true()

	await close_game(game)
	var expected_files := [
		"screenshot.png",
		"scene_tree.json",
		"engine_logs.json",
		"stdout.log",
		"stderr.log",
	]
	for file_name in expected_files:
		assert_bool(FileAccess.file_exists(artifact_directory + "/" + file_name)).is_true()
	var artifact_files := _artifact_files(artifact_directory)
	assert_int(artifact_files.size()).is_equal(expected_files.size())
	for file_name in expected_files:
		assert_bool(artifact_files.has(file_name)).is_true()


func _remove_artifact_directory(artifact_directory: String) -> void:
	if not DirAccess.dir_exists_absolute(artifact_directory):
		return
	var directory := DirAccess.open(artifact_directory)
	if directory == null:
		return
	directory.list_dir_begin()
	while true:
		var entry := directory.get_next()
		if entry.is_empty():
			break
		var path := artifact_directory.path_join(entry)
		if directory.current_is_dir():
			_remove_artifact_directory(path)
		else:
			DirAccess.remove_absolute(path)
	directory.list_dir_end()
	DirAccess.remove_absolute(artifact_directory)


func _artifact_files(artifact_directory: String) -> Array:
	var files: Array = []
	var directory := DirAccess.open(artifact_directory)
	if directory == null:
		return files
	directory.list_dir_begin()
	while true:
		var entry := directory.get_next()
		if entry.is_empty():
			break
		if not directory.current_is_dir():
			files.append(entry)
	directory.list_dir_end()
	return files


func _artifact_directory(test_name: String) -> String:
	return ProjectSettings.globalize_path(
		"res://test_output/%s/%s" % [get_name(), test_name]
	)
