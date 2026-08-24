extends Node

const Framing = preload("res://addons/gdunit_e2e/protocol/e2e_framing.gd")

var received_messages: Array = []

var _server: TCPServer
var _peer: StreamPeerTCP
var _recv_buffer := PackedByteArray()
var _response_queue: Array = []
var _outgoing: Dictionary = {}


func start(port: int = 0) -> int:
	stop()
	_server = TCPServer.new()
	return _server.listen(port, "127.0.0.1")


func get_port() -> int:
	if _server == null:
		return -1
	return _server.get_local_port()


func queue_response(response: Dictionary, chunk_size: int = 0) -> void:
	_response_queue.append({
		"kind": "frame",
		"data": response.duplicate(true),
		"chunk_size": chunk_size,
	})


func queue_raw(data: PackedByteArray, chunk_size: int = 0) -> void:
	_response_queue.append({
		"kind": "raw",
		"data": data,
		"chunk_size": chunk_size,
	})


func queue_disconnect() -> void:
	_response_queue.append({"kind": "disconnect"})


func disconnect_peer() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
	_peer = null


func stop() -> void:
	disconnect_peer()
	if _server != null:
		_server.stop()
	_server = null
	_recv_buffer = PackedByteArray()
	_outgoing = {}


func _process(_delta: float) -> void:
	_accept_connection()
	if _peer == null:
		return

	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		disconnect_peer()
		return

	_read_requests()
	_flush_outgoing()


func _accept_connection() -> void:
	if _peer != null or _server == null:
		return
	if not _server.is_connection_available():
		return
	_peer = _server.take_connection()
	_recv_buffer = PackedByteArray()


func _read_requests() -> void:
	while _peer != null and _peer.get_available_bytes() > 0:
		var result: Array = _peer.get_data(_peer.get_available_bytes())
		if result[0] != OK:
			disconnect_peer()
			return
		_recv_buffer.append_array(result[1])

	while _peer != null:
		var extracted := Framing.try_extract(_recv_buffer)
		if not extracted.get("complete", false):
			return
		var consumed: int = extracted.get("consumed_bytes", 0)
		_recv_buffer = _recv_buffer.slice(consumed)
		if extracted.has("error"):
			continue
		received_messages.append(extracted.get("message", {}))
		_queue_next_response()


func _queue_next_response() -> void:
	if _response_queue.is_empty() or _peer == null:
		return
	var queued: Dictionary = _response_queue.pop_front()
	if queued.get("kind", "") == "disconnect":
		disconnect_peer()
		return

	var frame: PackedByteArray
	if queued.get("kind", "") == "raw":
		frame = queued.get("data", PackedByteArray())
	else:
		frame = Framing.encode_json(queued.get("data", {}))
	_outgoing = {
		"frame": frame,
		"offset": 0,
		"chunk_size": int(queued.get("chunk_size", 0)),
	}


func _flush_outgoing() -> void:
	if _peer == null or _outgoing.is_empty():
		return
	var frame: PackedByteArray = _outgoing.get("frame", PackedByteArray())
	var offset: int = _outgoing.get("offset", 0)
	var chunk_size: int = _outgoing.get("chunk_size", 0)
	var write_size := frame.size() - offset
	if chunk_size > 0:
		write_size = min(write_size, chunk_size)
	if write_size <= 0:
		_outgoing = {}
		return

	var error := _peer.put_data(frame.slice(offset, offset + write_size))
	if error != OK:
		disconnect_peer()
		return
	offset += write_size
	if offset >= frame.size():
		_outgoing = {}
	else:
		_outgoing["offset"] = offset
