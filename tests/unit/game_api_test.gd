extends GdUnitTestSuite

const E2EResultScript = preload("res://addons/gdunit_e2e/client/e2e_result.gd")
const Protocol = preload("res://addons/gdunit_e2e/protocol/e2e_protocol.gd")

var _game_script = null


class _RecordingClient extends RefCounted:
	var calls: Array = []
	var responses: Dictionary = {}

	func queue_response(action: String, result) -> void:
		if not responses.has(action):
			responses[action] = []
		responses[action].append(result)

	func send_command(action: String, parameters := {}, timeout_seconds := Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS):
		calls.append({
			"action": action,
			"parameters": parameters,
			"timeout": timeout_seconds,
		})
		if responses.has(action) and not responses[action].is_empty():
			return responses[action].pop_front()
		return E2EResultScript.new(true, {"id": calls.size(), "ok": true})


class _RecordingSuite extends RefCounted:
	var failures: Array = []

	func fail(message: String) -> void:
		failures.append(message)


func before_test() -> void:
	_game_script = load("res://addons/gdunit_e2e/client/gdunit_e2e_game.gd")


func test_wrapper_preserves_upstream_actions_parameters_and_values() -> void:
	var client := _RecordingClient.new()
	var suite := _RecordingSuite.new()
	var game = _new_game(client, suite)
	if game == null:
		return

	client.queue_response("node_exists", E2EResultScript.new(true, {"exists": true}))
	assert_bool(await game.node_exists("/root/Main")).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "node_exists",
		"parameters": {"path": "/root/Main"},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	client.queue_response("get_property", E2EResultScript.new(true, {"result": "ready"}))
	assert_str(await game.get_property("/root/Main/Status", "text")).is_equal("ready")
	assert_that(client.calls[-1]).is_equal({
		"action": "get_property",
		"parameters": {"path": "/root/Main/Status", "property": "text"},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	client.queue_response("set_property", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.set_property("/root/Main/Status", "text", "changed")).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "set_property",
		"parameters": {"path": "/root/Main/Status", "property": "text", "value": "changed"},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	client.queue_response("call_method", E2EResultScript.new(true, {"result": 3}))
	assert_int(await game.call_method("/root/Main", "get_child_count", [])).is_equal(3)
	assert_that(client.calls[-1]).is_equal({
		"action": "call_method",
		"parameters": {"path": "/root/Main", "method": "get_child_count", "args": []},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	client.queue_response("get_tree", E2EResultScript.new(true, {"tree": {"name": "Root"}}))
	assert_that(await game.get_tree("/root", 4)).is_equal({"name": "Root"})
	assert_that(client.calls[-1]).is_equal({
		"action": "get_tree",
		"parameters": {"path": "/root", "depth": 4},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	client.queue_response("get_scene", E2EResultScript.new(true, {"scene": "res://main.tscn"}))
	assert_str(await game.get_scene()).is_equal("res://main.tscn")
	assert_that(client.calls[-1]).is_equal({
		"action": "get_scene",
		"parameters": {},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	client.queue_response("input_action", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.input_action("ui_accept", true, 0.75)).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "input_action",
		"parameters": {"action_name": "ui_accept", "pressed": true, "strength": 0.75},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	client.queue_response("input_action", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.press_action("ui_accept", 0.5)).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "input_action",
		"parameters": {"action_name": "ui_accept", "pressed": true, "strength": 0.5},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	client.queue_response("input_key", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.input_key(KEY_A, false, true)).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "input_key",
		"parameters": {"keycode": KEY_A, "pressed": false, "physical": true},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	client.queue_response("input_mouse_button", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.input_mouse_button(12.5, 24.0, MOUSE_BUTTON_RIGHT, false)).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "input_mouse_button",
		"parameters": {"x": 12.5, "y": 24.0, "button": MOUSE_BUTTON_RIGHT, "pressed": false},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	client.queue_response("click_node", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.click_node("/root/Main/Button")).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "click_node",
		"parameters": {"path": "/root/Main/Button"},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	for action in ["wait_process_frames", "wait_physics_frames"]:
		client.queue_response(action, E2EResultScript.new(true, {"ok": true}))
		var wait_result: bool
		if action == "wait_process_frames":
			wait_result = await game.wait_process_frames(2)
		else:
			wait_result = await game.wait_physics_frames(2)
		assert_bool(wait_result).is_true()
		assert_that(client.calls[-1]).is_equal({
			"action": action,
			"parameters": {"count": 2},
			"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
		})

	client.queue_response("wait_seconds", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.wait_seconds(3.0)).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "wait_seconds",
		"parameters": {"seconds": 3.0},
		"timeout": 4.0,
	})

	client.queue_response("wait_for_node", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.wait_for_node("/root/Main", 5.0)).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "wait_for_node",
		"parameters": {"path": "/root/Main", "timeout": 5.0},
		"timeout": 6.0,
	})

	client.queue_response("wait_for_property", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.wait_for_property("/root/Main/Status", "text", "ready", 2.5)).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "wait_for_property",
		"parameters": {"path": "/root/Main/Status", "property": "text", "value": "ready", "timeout": 2.5},
		"timeout": 3.5,
	})

	client.queue_response("wait_for_signal", E2EResultScript.new(true, {"result": ["payload"]}))
	assert_that(await game.wait_for_signal("/root/Main", "ready", 1.0)).is_equal(["payload"])
	assert_that(client.calls[-1]).is_equal({
		"action": "wait_for_signal",
		"parameters": {"path": "/root/Main", "signal_name": "ready", "timeout": 1.0},
		"timeout": 2.0,
	})

	client.queue_response("change_scene", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.change_scene("res://next.tscn")).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "change_scene",
		"parameters": {"scene_path": "res://next.tscn"},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS + Protocol.WAIT_MARGIN_SECONDS,
	})

	client.queue_response("reload_scene", E2EResultScript.new(true, {"ok": true}))
	assert_bool(await game.reload_scene()).is_true()
	assert_that(client.calls[-1]).is_equal({
		"action": "reload_scene",
		"parameters": {},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS + Protocol.WAIT_MARGIN_SECONDS,
	})

	client.queue_response("screenshot", E2EResultScript.new(true, {"path": "/tmp/capture.png"}))
	assert_str(await game.screenshot("/tmp/capture.png")).is_equal("/tmp/capture.png")
	assert_that(client.calls[-1]).is_equal({
		"action": "screenshot",
		"parameters": {"save_path": "/tmp/capture.png"},
		"timeout": Protocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
	})

	assert_array(suite.failures).is_empty()


func test_raw_send_command_returns_failure_without_failing_suite() -> void:
	var client := _RecordingClient.new()
	var suite := _RecordingSuite.new()
	var game = _new_game(client, suite)
	if game == null:
		return

	client.queue_response("missing", E2EResultScript.new(false, null, "Node not found"))
	var result = await game.send_command("missing", {"path": "/root/Missing"}, 0.25)

	assert_bool(result.ok).is_false()
	assert_str(result.message).is_equal("Node not found")
	assert_array(suite.failures).is_empty()
	assert_that(client.calls[-1]).is_equal({
		"action": "missing",
		"parameters": {"path": "/root/Missing"},
		"timeout": 0.25,
	})


func test_convenience_failure_calls_public_suite_fail_and_returns_fallback() -> void:
	var client := _RecordingClient.new()
	var suite := _RecordingSuite.new()
	var game = _new_game(client, suite)
	if game == null:
		return

	client.queue_response("get_property", E2EResultScript.new(false, null, "Property unavailable"))
	var value = await game.get_property("/root/Missing", "text")

	assert_that(value).is_null()
	assert_that(suite.failures).is_equal(["Property unavailable"])


func _new_game(client, suite):
	if _game_script == null:
		fail("GdUnitE2EGame implementation is missing")
		return null
	return _game_script.new(client, suite)
