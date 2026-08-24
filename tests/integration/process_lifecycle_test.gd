extends GdUnitTestSuite

const LaunchOptions = preload("res://addons/gdunit_e2e/client/e2e_launch_options.gd")
const E2EProcessScript = preload("res://addons/gdunit_e2e/client/e2e_process.gd")

var _process = null


class _NeverDiesProcess extends E2EProcess:
	func is_running() -> bool:
		return true

	func _wait_for_death(_timeout_millis: int) -> bool:
		return false

	func _force_kill() -> bool:
		return false


func after_test() -> void:
	if is_instance_valid(_process):
		await _process.close()
		_process.queue_free()
		_process = null


func test_launch_owns_client_and_gracefully_reaps_the_real_child() -> void:
	var result = await _launch()
	assert_bool(result.ok).is_true()
	assert_bool(_process.is_running()).is_true()
	assert_int(_process.get_port()).is_greater(0)
	assert_bool(_process.get_client().get_parent() == _process).is_true()
	assert_bool(_process.get_port_file().begins_with("user://tmp/gdunit_e2e/port_")).is_true()
	assert_bool(_process.get_stdout().is_empty()).is_true()

	var started := Time.get_ticks_msec()
	await _process.close()
	var elapsed := Time.get_ticks_msec() - started

	assert_bool(_process.is_running()).is_false()
	assert_bool(OS.is_process_running(_process.get_pid())).is_false()
	assert_bool(elapsed < 4000).is_true()
	assert_bool(_process.get_port_file().is_empty() or not FileAccess.file_exists(_process.get_port_file())).is_true()
	assert_bool(_process.get_stdout() is String).is_true()
	assert_bool(_process.get_stderr() is String).is_true()


func test_close_force_kills_an_authenticated_child_when_the_client_is_gone() -> void:
	var result = await _launch()
	assert_bool(result.ok).is_true()
	var pid: int = _process.get_pid()
	_process.get_client().close()

	var started := Time.get_ticks_msec()
	await _process.close()
	var elapsed := Time.get_ticks_msec() - started

	assert_bool(OS.is_process_running(pid)).is_false()
	assert_bool(_process.is_running()).is_false()
	assert_bool(elapsed < 4000).is_true()


func test_close_does_not_complete_without_observing_pid_death() -> void:
	var process := _NeverDiesProcess.new(self)
	add_child(process)
	process._pid = 12345

	await process.close()

	assert_bool(process._close_complete).is_false()
	assert_bool(process._close_started).is_false()
	assert_str(process.get_close_error()).contains("Unable to confirm")
	process.queue_free()


func test_close_is_idempotent_after_the_child_has_been_reaped() -> void:
	var result = await _launch()
	assert_bool(result.ok).is_true()
	await _process.close()
	var first_exit_code: int = _process.get_exit_code()

	await _process.close()

	assert_int(_process.get_exit_code()).is_equal(first_exit_code)
	assert_bool(_process.is_running()).is_false()


func test_launch_rejects_a_project_outside_the_current_tree() -> void:
	var options = _options()
	options.project_path = "/private/tmp/not-the-current-godot-project"
	_process = E2EProcessScript.new(self)
	add_child(_process)

	var result = await _process.launch(options)

	assert_bool(result.ok).is_false()
	assert_str(result.message).contains("current in-tree project")
	assert_bool(_process.is_running()).is_false()


func _launch():
	_process = E2EProcessScript.new(self)
	add_child(_process)
	return await _process.launch(_options())


func _options():
	var options = LaunchOptions.new()
	options.project_path = ProjectSettings.globalize_path("res://")
	options.godot_path = "/Users/chanwaichan/.local/bin/godot"
	options.timeout_seconds = 5.0
	options.extra_godot_args = PackedStringArray(["--headless", "--quiet"])
	return options
