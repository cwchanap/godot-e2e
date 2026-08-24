class_name E2EClient
extends Node

const E2EProtocol = preload("../protocol/e2e_protocol.gd")
const E2EFraming = preload("../protocol/e2e_framing.gd")
const E2ESerializer = preload("../protocol/e2e_serializer.gd")
const E2EResultScript = preload("e2e_result.gd")

signal _pending_completed(result)

var _peer: StreamPeerTCP
var _recv_buffer := PackedByteArray()
var _next_id: int = 1
var _session_open := false

var _pending_id: int = 0
var _pending_deadline_ms: int = 0
var _pending_timeout_ms: int = 0
var _pending_action: String = ""
var _pending_packet := PackedByteArray()
var _pending_sent := false

var _collected_logs: Array = []


func connect_to_server(
	port: int,
	token: String,
	timeout_seconds := E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
):
	if _pending_id != 0:
		return _failure("A command is already in flight")
	if not is_inside_tree():
		return _failure("E2EClient must be inside the SceneTree before connecting")

	close()
	_peer = StreamPeerTCP.new()
	_recv_buffer = PackedByteArray()
	_session_open = false
	var connect_error := _peer.connect_to_host("127.0.0.1", port)
	if connect_error != OK:
		_drop_peer()
		return _failure("Failed to connect to 127.0.0.1:%d (error %d)" % [port, connect_error])

	var hello_id := _allocate_id()
	var hello := {
		"id": hello_id,
		"action": "hello",
		"token": token,
		"protocol_version": E2EProtocol.PROTOCOL_VERSION,
	}
	var hello_frame := E2EFraming.encode_json(hello)
	if hello_frame.is_empty():
		_drop_peer()
		return _failure("Failed to encode hello command")
	_begin_pending(hello_id, "hello", timeout_seconds, hello_frame)
	var result = await _wait_for_pending()
	return result


func send_command(
	action: String,
	parameters := {},
	timeout_seconds := E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS,
):
	if _pending_id != 0:
		return _failure("A command is already in flight")
	if not is_session_open():
		return _failure("E2E session is not open")

	var command_id := _allocate_id()
	var command := {"id": command_id, "action": action}
	if parameters is Dictionary:
		for key in parameters:
			command[key] = E2ESerializer.serialize(parameters[key])
	var frame := E2EFraming.encode_json(command)
	if frame.is_empty():
		return _failure("Failed to encode command '%s'" % action)
	_begin_pending(command_id, action, timeout_seconds, frame)
	var result = await _wait_for_pending()
	return result


func close() -> void:
	if _pending_id != 0:
		_drop_peer()
		_finish_pending(_failure("Connection closed"))
		return
	_drop_peer()


func is_session_open() -> bool:
	return _session_open and _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func reset_collected_logs() -> void:
	_collected_logs.clear()


func get_collected_logs() -> Array:
	return _collected_logs.duplicate(true)


func _process(_delta: float) -> void:
	if _peer == null:
		return
	_peer.poll()
	var status := _peer.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		_send_pending_packet_if_ready()
		_read_available_bytes()
		_extract_complete_frames()
		_expire_pending_request_if_needed()
	elif status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		if _pending_id != 0:
			var result = _failure("Connection lost while waiting for '%s'" % _pending_action)
			_drop_peer()
			_finish_pending(result)
		else:
			_drop_peer()
	else:
		_expire_pending_request_if_needed()


func _wait_for_pending():
	var result = await _pending_completed
	return result


func _begin_pending(id: int, action: String, timeout_seconds: float, frame: PackedByteArray) -> void:
	_pending_id = id
	_pending_action = action
	_pending_timeout_ms = max(1, int(timeout_seconds * 1000.0))
	_pending_deadline_ms = Time.get_ticks_msec() + _pending_timeout_ms
	_pending_packet = frame
	_pending_sent = false


func _send_pending_packet_if_ready() -> void:
	if _peer == null or _pending_id == 0 or _pending_sent:
		return
	var error := _peer.put_data(_pending_packet)
	if error != OK:
		_drop_peer()
		_finish_pending(_failure("Failed to send '%s' (error %d)" % [_pending_action, error]))
		return
	_pending_sent = true


func _read_available_bytes() -> void:
	while _peer != null:
		var available := _peer.get_available_bytes()
		if available <= 0:
			return
		var result: Array = _peer.get_data(available)
		if result[0] != OK:
			if _pending_id != 0:
				var read_error = _failure("Failed to read response (error %d)" % result[0])
				_drop_peer()
				_finish_pending(read_error)
			else:
				_drop_peer()
			return
		_recv_buffer.append_array(result[1])


func _extract_complete_frames() -> void:
	while _peer != null:
		var extracted := E2EFraming.try_extract(_recv_buffer)
		if extracted.get("error", "") == "frame_too_large":
			if _pending_id != 0:
				var frame_error = _failure(
					"Response frame declaration exceeds %d bytes" % E2EProtocol.MAX_FRAME_BYTES
				)
				_drop_peer()
				_finish_pending(frame_error)
			else:
				_drop_peer()
			return
		if not extracted.get("complete", false):
			return

		var consumed: int = extracted.get("consumed_bytes", 0)
		_recv_buffer = _recv_buffer.slice(consumed)
		if extracted.has("error"):
			_finish_pending(_failure(_render_frame_error(extracted.get("error", "invalid_message"))))
			continue
		_handle_response(extracted.get("message", {}))
		if _pending_id == 0:
			return


func _handle_response(response: Dictionary) -> void:
	if _pending_id == 0:
		return
	var response_id = response.get("id", null)
	if not response.has("id") and response.has("error"):
		response_id = _pending_id
	if response_id != _pending_id:
		var id_error = _failure("Unexpected response id %s for '%s'" % [str(response_id), _pending_action])
		_drop_peer()
		_finish_pending(id_error)
		return

	var logs := _extract_logs(response)
	var result
	if response.has("error"):
		result = E2EResultScript.new(false, _response_value(response), _render_error(response), logs)
	else:
		result = E2EResultScript.new(true, _response_value(response), "", logs)
	if _pending_action == "hello" and not result.ok:
		_drop_peer()
	_finish_pending(result)


func _extract_logs(response: Dictionary) -> Array:
	var entries: Array = []
	var raw_logs = response.get("_logs", [])
	if raw_logs is Array:
		for raw_entry in raw_logs:
			entries.append(E2ESerializer.deserialize(raw_entry))
	var dropped := int(response.get("_logs_dropped", 0))
	if dropped > 0:
		entries.append({
			"level": "warning",
			"message": "<%d log entries dropped due to capture buffer overflow>" % dropped,
		})
	for entry in entries:
		_collected_logs.append(entry)
	return entries


func _response_value(response: Dictionary) -> Variant:
	var value := response.duplicate(true)
	value.erase("_logs")
	value.erase("_logs_dropped")
	return E2ESerializer.deserialize(value)


func _render_error(response: Dictionary) -> String:
	var error_text := str(response.get("error", ""))
	var detail := str(response.get("message", ""))
	if error_text.is_empty():
		return detail
	if detail.is_empty() or detail == error_text:
		return error_text
	return "%s: %s" % [error_text, detail]


func _render_frame_error(error_code: String) -> String:
	match error_code:
		"invalid_json":
			return "Invalid JSON response"
		"invalid_message":
			return "Invalid response message"
		_:
			return error_code


func _expire_pending_request_if_needed() -> void:
	if _pending_id == 0 or Time.get_ticks_msec() < _pending_deadline_ms:
		return
	var result = _failure(
		"Command '%s' timed out after %d ms" % [_pending_action, _pending_timeout_ms]
	)
	var is_hello := _pending_action == "hello"
	if is_hello:
		_drop_peer()
	_finish_pending(result)


func _finish_pending(result) -> void:
	if _pending_id == 0:
		return
	var action := _pending_action
	_pending_id = 0
	_pending_deadline_ms = 0
	_pending_timeout_ms = 0
	_pending_action = ""
	_pending_packet = PackedByteArray()
	_pending_sent = false
	if action == "hello":
		_session_open = result.ok
	_pending_completed.emit(result)


func _allocate_id() -> int:
	var id := _next_id
	_next_id += 1
	return id


func _failure(message: String):
	return E2EResultScript.new(false, null, message, [])


func _drop_peer() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
	_peer = null
	_recv_buffer = PackedByteArray()
	_pending_packet = PackedByteArray()
	_pending_sent = false
	_session_open = false
