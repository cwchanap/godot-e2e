extends GdUnitTestSuite

const E2EFramingScript = preload("res://addons/gdunit_e2e/protocol/e2e_framing.gd")
const LaunchOptions = preload("res://addons/gdunit_e2e/client/e2e_launch_options.gd")
const E2EProcessScript = preload("res://addons/gdunit_e2e/client/e2e_process.gd")

var _process = null


func after_test() -> void:
	if is_instance_valid(_process):
		await _process.close()
		_process.queue_free()
		_process = null


func test_real_server_writes_a_nonzero_ephemeral_port_and_handles_node_access() -> void:
	var result = await _launch()
	assert_bool(result.ok).is_true()
	assert_bool(FileAccess.file_exists(_process.get_port_file())).is_true()
	assert_int(_process.get_port()).is_greater(0)

	var client = _process.get_client()
	var scene_result = await client.send_command("get_scene")
	assert_bool(scene_result.ok).is_true()
	assert_str(scene_result.value["scene"]).is_equal(
		"res://tests/fixtures/minimal/main.tscn"
	)

	var root_result = await client.send_command("node_exists", {"path": "/root/Main"})
	assert_bool(root_result.ok).is_true()
	assert_bool(root_result.value["exists"]).is_true()

	var bootstrap_result = await client.send_command(
		"node_exists",
		{"path": "/root/GdUnitE2EBootstrapRunner"},
	)
	assert_bool(bootstrap_result.ok).is_true()
	assert_bool(bootstrap_result.value["exists"]).is_false()

	var node_result = await client.send_command("node_exists", {"path": "/root/Main"})
	var property_result = await client.send_command("get_property", {
		"path": "/root/Main/Status",
		"property": "text",
	})

	assert_bool(node_result.ok).is_true()
	assert_bool(node_result.value["exists"]).is_true()
	assert_bool(property_result.ok).is_true()
	assert_str(property_result.value["result"]).is_equal("ready")

	var changed = await client.send_command(
		"change_scene",
		{"scene_path": "res://tests/fixtures/minimal/main.tscn"},
		6.0,
	)
	assert_bool(changed.ok).is_true()

	var after_change = await client.send_command("node_exists", {"path": "/root/Main"})
	assert_bool(after_change.ok).is_true()
	assert_bool(after_change.value["exists"]).is_true()


func test_startup_error_logs_cross_bootstrap_boundary() -> void:
	var result = await _launch("res://tests/fixtures/startup_error/main.tscn")
	assert_bool(result.ok).is_true()

	var found_startup_error := false
	for entry in _process.get_client().get_collected_logs():
		if String(entry.get("message", "")).contains("gdunit-e2e startup error fixture"):
			found_startup_error = true
			break
	assert_bool(found_startup_error).is_true()


func test_invalid_target_scene_exits_before_port_file_consumption() -> void:
	var options = _options()
	options.scene_path = "res://does_not_exist.tscn"
	_process = E2EProcessScript.new(self)
	add_child(_process)

	var result = await _process.launch(options)

	assert_bool(result.ok).is_false()
	assert_bool(_process.is_running()).is_false()
	assert_bool(OS.is_process_running(_process.get_pid())).is_false()
	assert_int(_process.get_port()).is_equal(-1)
	assert_bool(
		_process.get_port_file().is_empty() or not FileAccess.file_exists(_process.get_port_file())
	).is_true()


func test_wrong_token_is_rejected_by_the_real_server() -> void:
	var result = await _launch()
	assert_bool(result.ok).is_true()
	var client = _process.get_client()
	client.close()

	var rejected = await client.connect_to_server(_process.get_port(), "wrong-token", 1.0)

	assert_bool(rejected.ok).is_false()
	assert_str(rejected.message).contains("auth_failed")


func test_non_hello_first_command_is_rejected_and_disconnected() -> void:
	var result = await _launch()
	assert_bool(result.ok).is_true()
	# The server accepts one connection at a time. Release the authenticated
	# launch client before opening the deliberately unauthenticated peer.
	_process.get_client().close()
	await await_millis(25)
	var peer := StreamPeerTCP.new()
	assert_int(peer.connect_to_host("127.0.0.1", _process.get_port())).is_equal(OK)
	var connect_deadline := Time.get_ticks_msec() + 1000
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < connect_deadline:
		peer.poll()
		await await_millis(25)
	assert_int(peer.get_status()).is_equal(StreamPeerTCP.STATUS_CONNECTED)
	var frame := E2EFramingScript.encode_json({"id": 1, "action": "node_exists", "path": "/root/Main"})
	assert_int(peer.put_data(frame)).is_equal(OK)

	var response: Dictionary = await _read_frame(peer)

	assert_str(response.get("error", "")).is_equal("not_authenticated")
	assert_str(response.get("message", "")).contains("First command")
	var disconnected_by_server: bool = await _wait_for_peer_disconnect(peer)
	assert_bool(disconnected_by_server).is_true()
	peer.disconnect_from_host()


func test_invalid_startup_configuration_never_listens_and_parent_reaps_child() -> void:
	var options = _options()
	options.timeout_seconds = 0.25
	options.log_verbosity = "invalid"
	var target_port := _unused_local_port()
	options.server_port = target_port
	_process = E2EProcessScript.new(self)
	add_child(_process)

	var result = await _process.launch(options)

	assert_bool(result.ok).is_false()
	assert_bool(_process.is_running()).is_false()
	assert_bool(OS.is_process_running(_process.get_pid())).is_false()
	assert_int(_process.get_port()).is_equal(-1)
	assert_bool(await _is_port_listening(target_port)).is_false()


func test_authenticated_disconnect_exits_child_after_orphan_grace() -> void:
	var result = await _launch()
	assert_bool(result.ok).is_true()
	_process.get_client().close()

	await await_millis(2400)

	assert_bool(_process.is_running()).is_false()
	assert_bool(OS.is_process_running(_process.get_pid())).is_false()


func test_reauthentication_within_grace_keeps_child_alive() -> void:
	var result = await _launch()
	assert_bool(result.ok).is_true()
	var client = _process.get_client()
	client.close()
	await await_millis(100)

	var reauthenticated = await client.connect_to_server(_process.get_port(), _process._token, 1.0)
	assert_bool(reauthenticated.ok).is_true()
	await await_millis(2200)

	assert_bool(_process.is_running()).is_true()


func _launch(scene_path := ""):
	_process = E2EProcessScript.new(self)
	add_child(_process)
	var options = _options()
	if not scene_path.is_empty():
		options.scene_path = scene_path
	return await _process.launch(options)


func _options():
	var options = LaunchOptions.new()
	options.project_path = ProjectSettings.globalize_path("res://")
	options.timeout_seconds = 5.0
	options.extra_godot_args = PackedStringArray(["--headless", "--quiet"])
	return options


func _unused_local_port() -> int:
	var server := TCPServer.new()
	assert_int(server.listen(0, "127.0.0.1")).is_equal(OK)
	var port := server.get_local_port()
	server.stop()
	return port


func _is_port_listening(port: int) -> bool:
	var peer := StreamPeerTCP.new()
	var connect_error := peer.connect_to_host("127.0.0.1", port)
	if connect_error != OK:
		return false
	var deadline := Time.get_ticks_msec() + 500
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()
			return true
		if peer.get_status() == StreamPeerTCP.STATUS_ERROR or peer.get_status() == StreamPeerTCP.STATUS_NONE:
			break
		await await_millis(25)
	peer.disconnect_from_host()
	return false


func _wait_for_peer_disconnect(peer: StreamPeerTCP) -> bool:
	var deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return true
		await await_millis(25)
	return false


func _read_frame(peer: StreamPeerTCP):
	var buffer := PackedByteArray()
	var deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_ERROR or peer.get_status() == StreamPeerTCP.STATUS_NONE:
			break
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			await await_millis(25)
			continue
		if peer.get_available_bytes() > 0:
			var data := peer.get_data(peer.get_available_bytes())
			if data[0] != OK:
				break
			buffer.append_array(data[1])
		var extracted := E2EFramingScript.try_extract(buffer)
		if extracted.get("complete", false):
			return extracted.get("message", {})
		await await_millis(25)
	return {}
