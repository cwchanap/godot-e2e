extends GdUnitTestSuite


const SUITE_PATH := "res://addons/gdunit_e2e/gdunit/gdunit_e2e_test_suite.gd"


class _RecordingSuite extends GdUnitE2ETestSuite:
	var failures: Array = []

	func fail(message: String) -> void:
		failures.append(message)


class _FakeClient extends RefCounted:
	var events: Array = []
	var timeline: Array = []

	func get_collected_logs() -> Array:
		events.append("logs")
		timeline.append("logs")
		return [{"level": "error", "message": "fake"}]


class _FakeProcess extends Node:
	var events: Array = []
	var client := _FakeClient.new()
	var timeline: Array = []

	func close() -> void:
		events.append("close")
		timeline.append("close")

	func get_client() -> _FakeClient:
		return client

	func get_stdout() -> String:
		events.append("stdout")
		timeline.append("stdout")
		return "fake stdout"

	func get_stderr() -> String:
		events.append("stderr")
		timeline.append("stderr")
		return "fake stderr"


class _FailingProcess extends _FakeProcess:
	func get_close_error() -> String:
		return "child is still alive"


class _FakeGame extends GdUnitE2EGame:
	var events: Array = []
	var screenshot_path := ""
	var timeline: Array = []

	func screenshot(_path := "") -> String:
		events.append("screenshot")
		timeline.append("screenshot")
		screenshot_path = _path
		return _path

	func get_tree(_path := "/root", _depth := 4) -> Dictionary:
		events.append("tree")
		timeline.append("tree")
		return {"name": "fake"}


func test_gdunit_e2e_suite_script_is_available() -> void:
	var suite_script = load(SUITE_PATH)
	assert_object(suite_script).is_not_null()


func test_artifacts_use_the_public_execution_context_test_name() -> void:
	var suite_script = load(SUITE_PATH)
	if suite_script == null:
		assert_object(suite_script).is_not_null()
		return
	var suite = suite_script.new()
	add_child(suite)
	suite.set_name("GdUnitSuiteTest")
	suite.set_active_test_case("test_artifacts_use_the_public_execution_context_test_name")
	var process := _FakeProcess.new()
	var game := _FakeGame.new()
	suite.add_child(process)
	suite.set("_tracked_games", [{"game": game, "process": process}])

	await suite.call("capture_failure_artifacts", game)

	assert_str(game.screenshot_path).contains(
		"/test_output/GdUnitSuiteTest/test_artifacts_use_the_public_execution_context_test_name/screenshot.png"
	)
	suite.queue_free()


#region lifecycle
func test_process_can_be_parented_to_the_suite_before_launch() -> void:
	var suite_script = load(SUITE_PATH)
	if suite_script == null:
		assert_object(suite_script).is_not_null()
		return
	var suite = suite_script.new()
	add_child(suite)
	var process := E2EProcess.new(suite)
	suite.add_child(process)

	assert_that(process.get_parent()).is_same(suite)

	suite.remove_child(process)
	process.queue_free()
	suite.queue_free()


func test_failed_launch_reports_and_reaps_the_tracked_process() -> void:
	var suite := _RecordingSuite.new()
	add_child(suite)
	var options := E2ELaunchOptions.new()
	options.godot_path = "/private/tmp/godot-e2e-missing-executable"

	var game := await suite.launch_game(options)

	assert_that(game).is_null()
	assert_array(suite.failures).has_size(1)
	assert_array(suite.get("_tracked_games")).is_empty()
	assert_int(suite.get_child_count()).is_equal(0)
	suite.queue_free()


func test_after_test_captures_reachable_artifacts_before_reaping() -> void:
	var suite_script = load(SUITE_PATH)
	if suite_script == null:
		assert_object(suite_script).is_not_null()
		return
	var suite = suite_script.new()
	add_child(suite)
	suite.set_name("GdUnitSuiteTest")
	suite.set_active_test_case("test_after_test_captures_reachable_artifacts_before_reaping")
	var process := _FakeProcess.new()
	var game := _FakeGame.new()
	suite.add_child(process)
	suite.set("_tracked_games", [{"game": game, "process": process}])
	Engine.set_meta("GD_TEST_FAILURE", true)

	await suite.call("after_test")
	Engine.remove_meta("GD_TEST_FAILURE")

	assert_array(game.events).contains_exactly("screenshot", "tree")
	assert_array(process.events).contains_exactly("close", "stdout", "stderr")
	assert_array(process.client.events).contains("logs")
	assert_bool(suite.get_child_count() == 0).is_true()
	assert_array(suite.get("_tracked_games")).is_empty()

	suite.queue_free()


func test_after_test_order_captures_then_reaps_and_drains() -> void:
	var suite_script = load(SUITE_PATH)
	if suite_script == null:
		assert_object(suite_script).is_not_null()
		return
	var suite = suite_script.new()
	add_child(suite)
	suite.set_name("GdUnitSuiteTest")
	var process := _FakeProcess.new()
	var game := _FakeGame.new()
	var timeline: Array = []
	process.timeline = timeline
	process.client.timeline = timeline
	game.timeline = timeline
	suite.add_child(process)
	suite.set("_tracked_games", [{"game": game, "process": process}])
	Engine.set_meta("GD_TEST_FAILURE", true)

	await suite.call("after_test")
	Engine.remove_meta("GD_TEST_FAILURE")

	assert_array(timeline).contains_exactly(
		"screenshot", "tree", "logs", "close", "stdout", "stderr"
	)
	assert_int(suite.get_child_count()).is_equal(0)
	suite.queue_free()


func test_after_test_reaps_tracked_process_without_failure_capture() -> void:
	var suite_script = load(SUITE_PATH)
	if suite_script == null:
		assert_object(suite_script).is_not_null()
		return
	var suite = suite_script.new()
	add_child(suite)
	var process := _FakeProcess.new()
	var game := _FakeGame.new()
	suite.add_child(process)
	suite.set("_tracked_games", [{"game": game, "process": process}])
	Engine.set_meta("GD_TEST_FAILURE", false)

	await suite.call("after_test")
	Engine.remove_meta("GD_TEST_FAILURE")

	assert_array(game.events).is_empty()
	assert_array(process.events).contains_exactly("close", "stdout", "stderr")
	assert_bool(suite.get_child_count() == 0).is_true()

	suite.queue_free()


func test_failed_reap_keeps_process_tracked_for_safety_retry() -> void:
	var suite := _RecordingSuite.new()
	add_child(suite)
	var process := _FailingProcess.new()
	var game := _FakeGame.new()
	suite.add_child(process)
	suite.set("_tracked_games", [{"game": game, "process": process}])

	await suite.call("after_test")

	assert_array(suite.failures).has_size(1)
	assert_array(suite.get("_tracked_games")).has_size(1)
	assert_that(process.get_parent()).is_same(suite)

	suite.set("_tracked_games", [])
	suite.remove_child(process)
	process.queue_free()
	suite.queue_free()


func test_before_test_reaps_unexpected_previous_processes() -> void:
	var suite_script = load(SUITE_PATH)
	if suite_script == null:
		assert_object(suite_script).is_not_null()
		return
	var suite = suite_script.new()
	add_child(suite)
	var process := _FakeProcess.new()
	var game := _FakeGame.new()
	suite.add_child(process)
	suite.set("_tracked_games", [{"game": game, "process": process}])

	await suite.call("before_test")

	assert_array(process.events).contains_exactly("close", "stdout", "stderr")
	assert_bool(suite.get_child_count() == 0).is_true()
	assert_array(suite.get("_tracked_games")).is_empty()

	suite.queue_free()
#endregion
