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


# Regression: without a whole-lifetime pipe drain the OS pipe buffer fills
# mid-test and the child blocks on its next stdout write, so commands stop
# completing. This calls a fixture method that print()s enough output to
# overflow a typical 64 KiB pipe buffer in a single command, then verifies a
# follow-up command still completes. Uses warning verbosity (not info) to
# avoid the log-capture feedback loop that triggers response_too_large before
# the pipe can fill.
func test_runtime_pipe_drain_keeps_commands_completing_under_load() -> void:
	var options = _options()
	# --quiet would suppress the fixture's print()s and defeat the test.
	options.extra_godot_args = PackedStringArray(["--headless"])
	_process = E2EProcessScript.new(self)
	add_child(_process)

	var result = await _process.launch(options)
	assert_bool(result.ok).is_true()
	if is_failure():
		return

	var client = _process.get_client()
	# 4000 lines * ~90 bytes = ~360 KiB, well past a 64 KiB pipe buffer. Without
	# live drain that keeps reading across OS-buffer-empty gaps, a slow parent
	# frame rate (Windows CI) lets the child block inside emit_noise.
	var noise_result = await client.send_command(
		"call_method",
		{"path": "/root/Main", "method": "emit_noise", "args": [4000]},
		10.0,
	)
	assert_bool(noise_result.ok).is_true()
	if is_failure():
		return

	# A follow-up command proves the session is still responsive after the
	# pipe-heavy call.
	var follow_up = await client.send_command("node_exists", {"path": "/root/Main"}, 3.0)
	assert_bool(follow_up.ok).is_true()


func _launch():
	_process = E2EProcessScript.new(self)
	add_child(_process)
	return await _process.launch(_options())


func _options():
	var options = LaunchOptions.new()
	options.project_path = ProjectSettings.globalize_path("res://")
	options.extra_godot_args = PackedStringArray(["--headless", "--quiet"])
	return options
