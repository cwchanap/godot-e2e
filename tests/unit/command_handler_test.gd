extends GdUnitTestSuite

const CommandHandler = preload("res://addons/gdunit_e2e/server/command_handler.gd")

var _fixture: Node
var _handler


func before_test() -> void:
	_fixture = Node.new()
	_fixture.name = "Task3Fixture"
	get_tree().root.add_child(_fixture)
	_handler = CommandHandler.new(get_tree().root)


func after_test() -> void:
	if is_instance_valid(_fixture):
		_fixture.queue_free()
	_fixture = null
	_handler = null


func test_node_and_property_commands_keep_upstream_response_shapes() -> void:
	var player := Node2D.new()
	player.name = "Player"
	player.position = Vector2(1.0, 2.0)
	_fixture.add_child(player)

	assert_that(_handler.execute({"id": 1, "action": "node_exists", "path": "/root/Task3Fixture/Player"})).is_equal(
		{"id": 1, "exists": true}
	)
	assert_that(_handler.execute({"id": 2, "action": "get_property", "path": "/root/Task3Fixture/Player", "property": "position"})).is_equal(
		{"id": 2, "result": {"_t": "v2", "x": 1.0, "y": 2.0}}
	)
	assert_that(_handler.execute({"id": 3, "action": "get_property", "path": "/root/Missing", "property": "position"})).is_equal(
		{"id": 3, "error": "Node not found: /root/Missing"}
	)


func test_property_mutation_and_method_calls_keep_upstream_response_shapes() -> void:
	var player := Node2D.new()
	player.name = "Player"
	_fixture.add_child(player)

	assert_that(_handler.execute({
		"id": 4,
		"action": "set_property",
		"path": "/root/Task3Fixture/Player",
		"property": "position:x",
		"value": 3.0,
	})).is_equal({"id": 4, "ok": true})
	assert_that(_handler.execute({
		"id": 5,
		"action": "call_method",
		"path": "/root/Task3Fixture/Player",
		"method": "get_child_count",
		"args": [],
	})).is_equal({"id": 5, "result": 0})


func test_tree_and_input_wait_commands_keep_upstream_response_shapes() -> void:
	var tree_result: Dictionary = _handler.execute({
		"id": 6,
		"action": "get_tree",
		"path": "/root/Task3Fixture",
		"depth": 1,
	})
	assert_int(tree_result.get("id", -1)).is_equal(6)
	assert_that(tree_result.get("tree", {}).get("name", "")).is_equal("Task3Fixture")

	assert_that(_handler.execute({"id": 7, "action": "input_key", "keycode": KEY_A, "pressed": true})).is_equal({
		"_deferred": true,
		"wait_type": "physics_frames",
		"count": 2,
		"id": 7,
		"response": {"id": 7, "ok": true},
	})
	assert_that(_handler.execute({"id": 8, "action": "wait_seconds", "seconds": 0.1})).is_equal({
		"_deferred": true,
		"wait_type": "seconds",
		"duration": 0.1,
		"id": 8,
		"response": {"id": 8, "ok": true},
	})

func test_wait_for_property_deserializes_tagged_values_like_set_property() -> void:
	var player := Node2D.new()
	player.name = "Player"
	_fixture.add_child(player)

	_handler.execute({
		"id": 40,
		"action": "set_property",
		"path": "/root/Task3Fixture/Player",
		"property": "position",
		"value": {"_t": "v2", "x": 1.0, "y": 2.0},
	})
	var wait_result: Dictionary = _handler.execute({
		"id": 41,
		"action": "wait_for_property",
		"path": "/root/Task3Fixture/Player",
		"property": "position",
		"value": {"_t": "v2", "x": 1.0, "y": 2.0},
		"timeout": 1.0,
	})
	# The wait value must be deserialized so automation_server compares Vector2 == Vector2,
	# matching what set_property stored on the node.
	assert_that(wait_result.get("value")).is_equal(Vector2(1.0, 2.0))


func test_scene_change_reload_screenshot_and_quit_keep_upstream_shapes() -> void:
	assert_that(_handler.execute({"id": 10, "action": "get_scene"})).is_equal({"id": 10, "error": "No current scene"})

	var scene_server := _SceneServer.new()
	var scene_handler = CommandHandler.new(scene_server)
	assert_that(scene_handler.execute({"id": 11, "action": "change_scene", "scene_path": "res://tests/fixtures/next.tscn"})).is_equal({
		"_deferred": true,
		"wait_type": "scene_change",
		"scene_path": "res://tests/fixtures/next.tscn",
		"id": 11,
		"response": {"id": 11, "ok": true},
	})
	assert_str(scene_server.tree.last_scene_path).is_equal("res://tests/fixtures/next.tscn")

	scene_server.tree.current_scene = _Scene.new("res://tests/fixtures/current.tscn")
	assert_that(scene_handler.execute({"id": 12, "action": "reload_scene"})).is_equal({
		"_deferred": true,
		"wait_type": "scene_change",
		"scene_path": "res://tests/fixtures/current.tscn",
		"id": 12,
		"response": {"id": 12, "ok": true},
	})
	assert_str(scene_server.tree.last_scene_path).is_equal("res://tests/fixtures/current.tscn")

	var screenshot_path := ProjectSettings.globalize_path("res://task3-command-handler-screenshot.png")
	var screenshot_handler = CommandHandler.new(_ScreenshotServer.new())
	var screenshot: Dictionary = screenshot_handler.execute({"id": 13, "action": "screenshot", "save_path": screenshot_path})
	assert_int(screenshot.get("id", -1)).is_equal(13)
	assert_bool(screenshot.get("ok", false)).is_true()
	assert_str(screenshot.get("path", "")).ends_with("task3-command-handler-screenshot.png")
	DirAccess.remove_absolute(screenshot_path)

	var quit_handler = CommandHandler.new(_QuitServer.new())
	assert_that(quit_handler.execute({"id": 14, "action": "quit", "exit_code": 0})).is_equal({"id": 14, "ok": true})


func test_click_node_keeps_upstream_response_shape() -> void:
	var clickable := Node2D.new()
	clickable.name = "Task3ClickableNode"
	_fixture.add_child(clickable)

	assert_that(_handler.execute({"id": 15, "action": "click_node", "path": str(clickable.get_path())})).is_equal({
		"_deferred": true,
		"wait_type": "physics_frames",
		"count": 2,
		"id": 15,
		"response": {"id": 15, "ok": true},
	})


class _QuitServer extends RefCounted:
	var tree := _QuitTree.new()

	func get_tree() -> _QuitTree:
		return tree


class _QuitTree extends RefCounted:
	var exit_code := -1

	func quit(code: int = 0) -> void:
		exit_code = code


class _SceneServer extends RefCounted:
	var tree := _SceneTree.new()

	func get_tree() -> _SceneTree:
		return tree


class _SceneTree extends RefCounted:
	var current_scene
	var last_scene_path := ""

	func change_scene_to_file(path: String) -> int:
		last_scene_path = path
		return OK


class _Scene extends RefCounted:
	var scene_file_path: String

	func _init(path: String) -> void:
		scene_file_path = path


class _ScreenshotServer extends RefCounted:
	var viewport := _ScreenshotViewport.new()

	func get_viewport() -> _ScreenshotViewport:
		return viewport


class _ScreenshotViewport extends RefCounted:
	var texture := _ScreenshotTexture.new()

	func get_texture() -> _ScreenshotTexture:
		return texture


class _ScreenshotTexture extends RefCounted:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)

	func get_image() -> Image:
		return image
