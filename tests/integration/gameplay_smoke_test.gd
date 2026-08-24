extends GdUnitTestSuite

const E2EProcessScript = preload("res://addons/gdunit_e2e/client/e2e_process.gd")
const E2ELaunchOptionsScript = preload("res://addons/gdunit_e2e/client/e2e_launch_options.gd")
const E2EGameScript = preload("res://addons/gdunit_e2e/client/gdunit_e2e_game.gd")
const Protocol = preload("res://addons/gdunit_e2e/protocol/e2e_protocol.gd")

var _process = null
var _game = null


class _RecordingSuite extends RefCounted:
	var failures: Array = []

	func fail(message: String) -> void:
		failures.append(message)


func after_test() -> void:
	if is_instance_valid(_process):
		await _process.close()
		_process.queue_free()
	_process = null
	_game = null


func test_real_input_and_click_update_remote_fixture_state() -> void:
	var game = await _launch_game()
	if game == null or is_failure():
		return

	var initial_count = await game.get_property("/root/Main", "action_count")
	if is_failure():
		return
	assert_int(int(initial_count)).is_equal(0)

	assert_bool(await game.press_action("ui_accept")).is_true()
	if is_failure():
		return
	var updated_count = await game.get_property("/root/Main", "action_count")
	if is_failure():
		return
	assert_int(int(updated_count)).is_equal(1)

	assert_bool(await game.click_node("/root/Main/Button")).is_true()
	if is_failure():
		return
	var click_status = await game.get_property("/root/Main/ClickStatus", "text")
	if is_failure():
		return
	assert_str(click_status).is_equal("clicked")

	await _process.close()
	assert_bool(_process.is_running()).is_false()
	assert_bool(OS.is_process_running(_process.get_pid())).is_false()
	_process.queue_free()
	_process = null


func test_server_timeout_survives_client_deadline_race() -> void:
	var game = await _launch_game()
	if game == null or is_failure():
		return

	var recording_suite := _RecordingSuite.new()
	var race_game = E2EGameScript.new(_process.get_client(), recording_suite)
	var server_timeout := 0.2
	var result = await race_game.send_command(
		"wait_for_node",
		{"path": "/root/NodeThatNeverExists", "timeout": server_timeout},
		server_timeout + Protocol.WAIT_MARGIN_SECONDS,
	)

	assert_bool(result.ok).is_false()
	assert_str(result.message).contains("timeout")
	assert_str(result.message).not_contains("timed out after 1200 ms")
	assert_array(recording_suite.failures).is_empty()


func _launch_game():
	_process = E2EProcessScript.new(self)
	add_child(_process)
	var options := E2ELaunchOptionsScript.new()
	options.project_path = ProjectSettings.globalize_path("res://")
	options.godot_path = _godot_executable()
	options.timeout_seconds = 5.0
	options.extra_godot_args = PackedStringArray(["--quiet"])
	var result = await _process.launch(options)
	if not result.ok:
		fail(result.message)
		return null
	_game = E2EGameScript.new(_process.get_client(), self)
	return _game


func _godot_executable() -> String:
	var configured := OS.get_environment("GODOT_BIN")
	return configured if not configured.is_empty() else OS.get_executable_path()
