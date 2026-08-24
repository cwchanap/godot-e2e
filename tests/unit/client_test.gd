extends GdUnitTestSuite

const FakeE2EServer = preload("res://tests/helpers/fake_e2e_server.gd")
const Protocol = preload("res://addons/gdunit_e2e/protocol/e2e_protocol.gd")

var _server
var _client


func before_test() -> void:
	_server = FakeE2EServer.new()
	add_child(_server)
	assert_int(_server.start(0)).is_equal(OK)


func after_test() -> void:
	if is_instance_valid(_client):
		_client.close()
		_client.queue_free()
		_client = null
	if is_instance_valid(_server):
		_server.stop()
		_server.queue_free()
		_server = null
	await get_tree().process_frame


#region connection
func test_hello_sends_token_and_protocol_version_and_opens_session() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true, "server_version": "fake"})

	var result = await client.connect_to_server(_server.get_port(), "secret")

	assert_bool(result.ok).is_true()
	assert_bool(client.is_session_open()).is_true()
	assert_that(client.get_parent()).is_equal(self)
	assert_array(_server.received_messages).has_size(1)
	assert_that(_server.received_messages[0]).is_equal({
		"id": 1.0,
		"action": "hello",
		"token": "secret",
		"protocol_version": 1.0,
	})


func test_request_ids_are_monotonic_and_command_success_shape_is_preserved() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true})
	_server.queue_response({"id": 2, "exists": true, "marker": "kept"})
	_server.queue_response({"id": 3, "ok": true})

	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()
	var first = await client.send_command("node_exists", {"path": "/root/Player"})
	var second = await client.send_command("set_property", {"value": Vector2(1, 2)})

	assert_bool(first.ok).is_true()
	assert_that(first.value).is_equal({"id": 2.0, "exists": true, "marker": "kept"})
	assert_bool(second.ok).is_true()
	assert_that(_server.received_messages[1]).is_equal({
		"id": 2.0,
		"action": "node_exists",
		"path": "/root/Player",
	})
	assert_that(_server.received_messages[2]).is_equal({
		"id": 3.0,
		"action": "set_property",
		"value": {"_t": "v2", "x": 1.0, "y": 2.0},
	})


func test_non_hello_success_and_error_resolve_waiters() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true})
	_server.queue_response({"id": 2, "ok": true, "result": "done"})
	_server.queue_response({"id": 3, "error": "rejected"})
	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()

	var success = await client.send_command("success", {}, 0.2)
	var failure = await client.send_command("failure", {}, 0.2)

	assert_bool(success.ok).is_true()
	assert_str(success.value["result"]).is_equal("done")
	assert_bool(failure.ok).is_false()
	assert_str(failure.message).is_equal("rejected")


func test_result_payload_deserializes_shared_typed_variant_tags() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true})
	_server.queue_response({"id": 2, "result": {"_t": "v2", "x": 3.5, "y": -4.0}})
	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()

	var result = await client.send_command("get_property", {})

	assert_bool(result.ok).is_true()
	assert_that(result.value["result"]).is_equal(Vector2(3.5, -4.0))


func test_partial_response_writes_are_reassembled() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true}, 1)
	_server.queue_response({"id": 2, "result": "split"}, 2)

	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()
	var result = await client.send_command("call_method", {})

	assert_bool(result.ok).is_true()
	assert_str(result.value["result"]).is_equal("split")


func test_session_state_is_false_before_connect_and_after_close() -> void:
	var client = _new_client()
	if client == null:
		return
	assert_bool(client.is_session_open()).is_false()
	_server.queue_response({"id": 1, "ok": true})
	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()
	assert_bool(client.is_session_open()).is_true()

	client.close()
	client.close()

	assert_bool(client.is_session_open()).is_false()
#endregion

#region failures
func test_error_only_response_is_a_failed_result() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true})
	_server.queue_response({"id": 2, "error": "Node not found"})
	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()

	var result = await client.send_command("node_exists", {})

	assert_bool(result.ok).is_false()
	assert_str(result.message).is_equal("Node not found")


func test_error_and_message_response_is_rendered_readably() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true})
	_server.queue_response({"id": 2, "error": "invalid_argument", "message": "bad value"})
	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()

	var result = await client.send_command("set_property", {})

	assert_bool(result.ok).is_false()
	assert_str(result.message).is_equal("invalid_argument: bad value")


func test_timeout_closes_session_before_a_later_request() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true})
	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()

	var timed_out = await client.send_command("wait", {}, 0.03)

	assert_bool(timed_out.ok).is_false()
	assert_str(timed_out.message).contains("timed out")
	assert_bool(client.is_session_open()).is_false()
	_server.queue_response({"id": 2, "ok": true})
	var next_result = await client.send_command("next", {}, 0.2)
	assert_bool(next_result.ok).is_false()
	assert_str(next_result.message).contains("not open")
	assert_array(_server.received_messages).has_size(2)


func test_disconnect_fails_the_pending_command() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true})
	_server.queue_disconnect()
	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()

	var result = await client.send_command("disconnect", {}, 0.5)

	assert_bool(result.ok).is_false()
	assert_str(result.message).contains("Connection")
	assert_bool(client.is_session_open()).is_false()


func test_oversized_response_declaration_fails_before_body_is_needed() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true})
	var header := PackedByteArray([
		((Protocol.MAX_FRAME_BYTES + 1) >> 24) & 0xff,
		((Protocol.MAX_FRAME_BYTES + 1) >> 16) & 0xff,
		((Protocol.MAX_FRAME_BYTES + 1) >> 8) & 0xff,
		(Protocol.MAX_FRAME_BYTES + 1) & 0xff,
	])
	_server.queue_raw(header)
	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()

	var result = await client.send_command("oversized", {}, 0.5)

	assert_bool(result.ok).is_false()
	assert_str(result.message).contains("frame")
	assert_bool(client.is_session_open()).is_false()


func test_oversized_response_header_with_body_bytes_caps_read_before_body_allocation() -> void:
	var client = _new_client()
	if client == null:
		return
	var peer := _BufferedPeer.new()
	client._peer = peer
	var declared_size := Protocol.MAX_FRAME_BYTES + 1
	var incoming := PackedByteArray()
	incoming.resize(4 + 32)
	incoming[0] = (declared_size >> 24) & 0xff
	incoming[1] = (declared_size >> 16) & 0xff
	incoming[2] = (declared_size >> 8) & 0xff
	incoming[3] = declared_size & 0xff
	peer.incoming = incoming

	client._read_available_bytes()

	assert_int(client._recv_buffer.size()).is_equal(4)
	assert_that(peer.read_sizes).is_equal([4])
	assert_int(peer.incoming.size()).is_equal(32)

	client._extract_complete_frames()
	assert_bool(peer.disconnected).is_true()
#endregion

#region logs and concurrency
func test_response_log_deltas_accumulate_and_can_be_reset() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({
		"id": 1,
		"ok": true,
		"_logs": [{"level": "info", "message": "hello"}],
	})
	_server.queue_response({
		"id": 2,
		"ok": true,
		"_logs": [{"level": "warning", "message": "careful"}],
		"_logs_dropped": 2,
	})
	var connected = await client.connect_to_server(_server.get_port(), "token")
	var command_result = await client.send_command("logs", {})

	assert_array(connected.logs).has_size(1)
	assert_str(connected.logs[0]["message"]).is_equal("hello")
	assert_array(command_result.logs).has_size(2)
	assert_str(command_result.logs[0]["message"]).is_equal("careful")
	assert_str(command_result.logs[1]["message"]).contains("2 log entries dropped")
	assert_array(client.get_collected_logs()).has_size(3)

	client.reset_collected_logs()
	assert_array(client.get_collected_logs()).is_empty()


func test_second_command_is_rejected_while_one_is_in_flight() -> void:
	var client = _new_client()
	if client == null:
		return
	_server.queue_response({"id": 1, "ok": true})
	assert_bool((await client.connect_to_server(_server.get_port(), "token")).ok).is_true()

	var runner := _CommandRunner.new()
	runner.client = client
	runner.action = "slow"
	client.add_child(runner)
	await get_tree().process_frame
	var second = await client.send_command("second", {})

	assert_bool(second.ok).is_false()
	assert_str(second.message).contains("in flight")
	_server.queue_response({"id": 2, "ok": true})
	var first = await runner.finished
	assert_bool(first.ok).is_true()


func test_send_command_requires_scene_tree() -> void:
	var client = _new_client(false)
	if client == null:
		return

	var result = await client.send_command("orphan", {}, 0.2)

	assert_bool(result.ok).is_false()
	assert_str(result.message).contains("SceneTree")
#endregion


func _new_client(add_to_tree: bool = true):
	var client_path := "res://addons/gdunit_e2e/client/e2e_client.gd"
	if not ResourceLoader.exists(client_path):
		fail("E2EClient implementation is missing")
		return null
	var script = load(client_path)
	if script == null:
		fail("E2EClient implementation could not be loaded")
		return null
	_client = script.new()
	if add_to_tree:
		add_child(_client)
	return _client




class _CommandRunner extends Node:
	signal finished(result)

	var client
	var action := ""


	func _ready() -> void:
		var result = await client.send_command(action, {}, 0.5)
		finished.emit(result)


class _BufferedPeer extends RefCounted:
	var incoming := PackedByteArray()
	var read_sizes: Array[int] = []
	var disconnected := false


	func get_available_bytes() -> int:
		return incoming.size()


	func get_data(size: int) -> Array:
		read_sizes.append(size)
		var data := incoming.slice(0, size)
		incoming = incoming.slice(size)
		return [OK, data]


	func disconnect_from_host() -> void:
		disconnected = true
