class_name GdUnitE2EGame
extends RefCounted

const E2EProtocol = preload("../protocol/e2e_protocol.gd")
const E2EResult = preload("e2e_result.gd")

const WAIT_MARGIN_SECONDS := E2EProtocol.WAIT_MARGIN_SECONDS

var _client = null
var _suite = null


func _init(client = null, suite = null) -> void:
	_client = client
	_suite = suite


func node_exists(path: String) -> bool:
	var result = await _request("node_exists", {"path": path})
	if not result.ok:
		return false
	return bool(_response(result).get("exists", false))


func get_property(path: String, property: String) -> Variant:
	var result = await _request("get_property", {"path": path, "property": property})
	if not result.ok:
		return null
	return _response(result).get("result", null)


func set_property(path: String, property: String, value: Variant) -> bool:
	var result = await _request("set_property", {
		"path": path,
		"property": property,
		"value": value,
	})
	return result.ok


func call_method(path: String, method: String, args := []) -> Variant:
	var result = await _request("call_method", {
		"path": path,
		"method": method,
		"args": args,
	})
	if not result.ok:
		return null
	return _response(result).get("result", null)


func get_tree(path := "/root", depth := 4) -> Dictionary:
	var result = await _request("get_tree", {"path": path, "depth": depth})
	if not result.ok:
		return {}
	var tree = _response(result).get("tree", {})
	return tree if tree is Dictionary else {}


func get_scene() -> String:
	var result = await _request("get_scene")
	if not result.ok:
		return ""
	return str(_response(result).get("scene", ""))


func input_action(action_name: String, pressed: bool, strength := 1.0) -> bool:
	var result = await _request("input_action", {
		"action_name": action_name,
		"pressed": pressed,
		"strength": strength,
	})
	return result.ok


func press_action(action_name: String, strength := 1.0) -> bool:
	var pressed := await input_action(action_name, true, strength)
	if not pressed:
		return false
	return await input_action(action_name, false, strength)


func input_key(keycode: int, pressed: bool, physical := false) -> bool:
	var result = await _request("input_key", {
		"keycode": keycode,
		"pressed": pressed,
		"physical": physical,
	})
	return result.ok


func input_mouse_button(x: float, y: float, button := 1, pressed := true) -> bool:
	var result = await _request("input_mouse_button", {
		"x": x,
		"y": y,
		"button": button,
		"pressed": pressed,
	})
	return result.ok


func click_node(path: String) -> bool:
	var result = await _request("click_node", {"path": path})
	return result.ok


func wait_process_frames(count := 1) -> bool:
	var result = await _request("wait_process_frames", {"count": count})
	return result.ok


func wait_physics_frames(count := 1) -> bool:
	var result = await _request("wait_physics_frames", {"count": count})
	return result.ok


func wait_seconds(seconds: float) -> bool:
	var result = await _request(
		"wait_seconds",
		{"seconds": seconds},
		seconds + WAIT_MARGIN_SECONDS,
	)
	return result.ok


func wait_for_node(path: String, timeout := 5.0) -> bool:
	var result = await _request(
		"wait_for_node",
		{"path": path, "timeout": timeout},
		timeout + WAIT_MARGIN_SECONDS,
	)
	return result.ok


func wait_for_property(path: String, property: String, value: Variant, timeout := 5.0) -> bool:
	var result = await _request(
		"wait_for_property",
		{
			"path": path,
			"property": property,
			"value": value,
			"timeout": timeout,
		},
		timeout + WAIT_MARGIN_SECONDS,
	)
	return result.ok


func wait_for_signal(path: String, signal_name: String, timeout := 5.0) -> Array:
	var result = await _request(
		"wait_for_signal",
		{"path": path, "signal_name": signal_name, "timeout": timeout},
		timeout + WAIT_MARGIN_SECONDS,
	)
	if not result.ok:
		return []
	var response := _response(result)
	var signal_args = response.get("result", response.get("args", []))
	return signal_args if signal_args is Array else []


func change_scene(scene_path: String) -> bool:
	var result = await _request(
		"change_scene",
		{"scene_path": scene_path},
		E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS + WAIT_MARGIN_SECONDS,
	)
	return result.ok


func reload_scene() -> bool:
	var result = await _request(
		"reload_scene",
		{},
		E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS + WAIT_MARGIN_SECONDS,
	)
	return result.ok


func screenshot(save_path := "") -> String:
	var result = await _request("screenshot", {"save_path": save_path})
	if not result.ok:
		return ""
	return str(_response(result).get("path", ""))


func send_command(
	action: String,
	parameters := {},
	timeout := E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
) -> E2EResult:
	if _client == null:
		return E2EResult.new(false, null, "E2E client is unavailable")
	return await _client.send_command(action, parameters, timeout)


func _request(
	action: String,
	parameters := {},
	timeout := E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
) -> E2EResult:
	var result: E2EResult = await send_command(action, parameters, timeout)
	if not result.ok:
		_fail(result.message)
	return result


func _response(result: E2EResult) -> Dictionary:
	return result.value if result.value is Dictionary else {}


func _fail(message: String) -> void:
	if _suite == null or not is_instance_valid(_suite) or not _suite.has_method("fail"):
		return
	_suite.fail(message)
