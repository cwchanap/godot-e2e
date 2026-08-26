## Main child-process TCP server for the GdUnit E2E addon.
##
## Non-blocking state machine that accepts a single TCP connection,
## authenticates via a hello/token handshake, and dispatches commands
## to command_handler.gd.
##
## Adapted from RandallLiuXin/godot-e2e at commit
## ae6219f6e758a0f29bd243c8f963417fe4d63c36 under Apache-2.0. The addon
## keeps the inherited command/wait behavior and adds loopback binding,
## shared framing, frame-size guards, and authenticated-peer orphan teardown.
extends Node

const Config = preload("config.gd")
const CommandHandlerScript = preload("command_handler.gd")
const LogCaptureScript = preload("log_capture.gd")
const E2EProtocolScript = preload("../protocol/e2e_protocol.gd")
const E2EFramingScript = preload("../protocol/e2e_framing.gd")

var _handler = null
var _log_capture = null

const SERVER_VERSION := "1.1.0"

enum State {
	LISTENING,
	IDLE,
	EXECUTING,
	WAITING,
	DISCONNECTED,
}

enum WaitType {
	NONE,
	PROCESS_FRAMES,
	PHYSICS_FRAMES,
	SECONDS,
	NODE_EXISTS,
	SIGNAL_EMITTED,
	PROPERTY_VALUE,
	SCENE_CHANGE,
}

# --- Networking ---
var _server: TCPServer = null
var _peer = null
var _recv_buffer: PackedByteArray = PackedByteArray()

# --- State machine ---
var _state: State = State.DISCONNECTED
var _authenticated: bool = false
var _ever_authenticated := false
var _orphan_deadline_ms := 0

# --- Pending command tracking ---
var _pending_id = null  # command id for the in-flight wait

# --- Wait state ---
var _wait_type: WaitType = WaitType.NONE
var _wait_process_remaining: int = 0
var _wait_physics_remaining: int = 0
var _wait_seconds_target: float = 0.0
var _wait_seconds_elapsed: float = 0.0
var _wait_node_path: String = ""
var _wait_signal_emitted: bool = false
var _wait_signal_connection: Callable = Callable()
var _wait_signal_source: Object = null
var _wait_signal_name: String = ""
var _wait_property_node_path: String = ""
var _wait_property_name: String = ""
var _wait_property_value = null
var _wait_scene_path: String = ""
var _wait_timeout_ms: int = 0
var _wait_start_ms: int = 0

# --- Physics frame counter ---
var _physics_frame_counter: int = 0

# --- Log capture ---
# Tracks the highest sequence number drained so far for the current
# connection. Reset to -1 on disconnect so the next session starts fresh
# (a brand new test run shouldn't inherit logs from a previous client).
var _last_drain_seq: int = -1


func set_log_capture(log_capture) -> void:
	_log_capture = log_capture


func _ready() -> void:
	if not Config.is_enabled():
		set_process(false)
		set_physics_process(false)
		return
	if not Config.is_valid():
		push_error("godot-e2e: %s" % Config.get_validation_error())
		set_process(false)
		set_physics_process(false)
		return

	# Register the engine log capture before anything else can emit. This
	# way the listen-error path below shows up in the capture buffer too.
	if _log_capture == null:
		_log_capture = LogCaptureScript.new()
		_log_capture.set_verbosity_str(Config.get_log_verbosity())
		OS.add_logger(_log_capture)

	_handler = CommandHandlerScript.new(self)

	_server = TCPServer.new()
	var requested_port := Config.get_port()
	var err := _server.listen(requested_port, "127.0.0.1")
	if err != OK:
		push_error("godot-e2e: failed to listen on port %d (error %d)" % [requested_port, err])
		set_process(false)
		set_physics_process(false)
		return
	var port := _server.get_local_port()

	var port_file := Config.get_port_file()
	if port_file != "":
		_write_port_file(port_file, port)

	_state = State.LISTENING
	_log("server listening on port %d" % port)


func _process(delta: float) -> void:
	if _orphan_deadline_ms > 0:
		if _authenticated:
			_orphan_deadline_ms = 0
		elif Time.get_ticks_msec() >= _orphan_deadline_ms:
			get_tree().quit()
			return

	match _state:
		State.LISTENING:
			_poll_listening()
		State.IDLE:
			_poll_connection_health()
			if _state == State.DISCONNECTED:
				return
			_poll_recv()
		State.WAITING:
			_poll_connection_health()
			if _state == State.DISCONNECTED:
				return
			_poll_wait(delta)
		State.DISCONNECTED:
			_handle_disconnect()


func _physics_process(_delta: float) -> void:
	_physics_frame_counter += 1
	if _state == State.WAITING and _wait_type == WaitType.PHYSICS_FRAMES:
		_wait_physics_remaining -= 1
		if _wait_physics_remaining <= 0:
			_send_response({"id": _pending_id, "ok": true})
			_transition_idle()


# ---------------------------------------------------------------------------
# Networking helpers
# ---------------------------------------------------------------------------

func _poll_listening() -> void:
	if _server == null:
		return
	if _server.is_connection_available():
		_peer = _server.take_connection()
		_recv_buffer = PackedByteArray()
		_authenticated = false
		_state = State.IDLE
		_log("client connected")


func _poll_connection_health() -> void:
	if _peer == null:
		_state = State.DISCONNECTED
		return
	_peer.poll()
	var status: int = _peer.get_status()
	if status != StreamPeerTCP.STATUS_CONNECTED:
		_log("connection lost (status %d)" % status)
		_state = State.DISCONNECTED


func _poll_recv() -> void:
	while true:
		# Read only the four-byte declaration first. This ensures an untrusted
		# length is validated before any body bytes enter the receive buffer.
		while _recv_buffer.size() < 4:
			if not _read_peer_bytes(4 - _recv_buffer.size()):
				return

		var declared_size: int = _decode_u32_be(_recv_buffer, 0)
		if declared_size > E2EProtocolScript.MAX_FRAME_BYTES:
			_log("inbound frame exceeds %d bytes" % E2EProtocolScript.MAX_FRAME_BYTES)
			_disconnect_peer()
			return

		var frame_size := 4 + declared_size
		while _recv_buffer.size() < frame_size:
			if not _read_peer_bytes(frame_size - _recv_buffer.size()):
				return

		# Extract complete length-prefixed messages. E2EFraming performs the
		# same declaration check for the shared primitive's callers.
		var extracted: Dictionary = E2EFramingScript.try_extract(_recv_buffer)
		if extracted.get("error", "") == "frame_too_large":
			_disconnect_peer()
			return
		if not extracted.get("complete", false):
			break

		var consumed: int = extracted.get("consumed_bytes", 0)
		_recv_buffer = _recv_buffer.slice(consumed)
		if extracted.has("error"):
			var extraction_error: String = extracted.get("error", "invalid_message")
			if extraction_error == "invalid_json":
				_send_response({"error": "invalid_json", "message": "Could not parse JSON"})
			else:
				_send_response({"error": "invalid_message", "message": "Expected JSON object"})
			continue

		_dispatch(extracted.get("message", {}))
		# After dispatch we may have entered WAITING; stop reading if so.
		if _state != State.IDLE:
			break


func _read_peer_bytes(max_bytes: int) -> bool:
	if _peer == null or max_bytes <= 0:
		return false
	var available: int = _peer.get_available_bytes()
	if available <= 0:
		return false
	var read_size: int = min(available, max_bytes)
	var result: Array = _peer.get_data(read_size)
	var error: int = result[0]
	var data: PackedByteArray = result[1]
	if error != OK:
		_log("recv error %d" % error)
		_state = State.DISCONNECTED
		return false
	_recv_buffer.append_array(data)
	return true


# ---------------------------------------------------------------------------
# Framing
# ---------------------------------------------------------------------------

func _send_response(data: Dictionary) -> void:
	if _peer == null:
		return
	# Drain any engine logs accumulated since the last response and attach
	# them to this payload. Done at the single send-out site so every
	# response (success, error, deferred) carries its delta.
	if _log_capture != null:
		var drained: Dictionary = _log_capture.drain_since(_last_drain_seq)
		var entries: Array = drained.get("entries", [])
		if entries.size() > 0:
			data["_logs"] = entries
		var dropped: int = drained.get("dropped", 0)
		if dropped > 0:
			data["_logs_dropped"] = dropped
		_last_drain_seq = drained.get("latest_seq", _last_drain_seq)

	var frame := _encode_response(data)
	if frame.is_empty():
		var compact := {
			"id": data.get("id", null),
			"error": "response_too_large",
			"message": "Response exceeded the 16 MiB frame limit",
		}
		frame = E2EFramingScript.encode_json(compact)
		if frame.is_empty():
			_disconnect_peer()
			return

	var error: int = _peer.put_data(frame)
	if error != OK:
		_log("send error %d" % error)
		_state = State.DISCONNECTED
	else:
		_log(">> %s" % frame.slice(4).get_string_from_utf8())


func _encode_response(data: Dictionary) -> PackedByteArray:
	var payload := JSON.stringify(data).to_utf8_buffer()
	if payload.size() > E2EProtocolScript.MAX_FRAME_BYTES:
		return PackedByteArray()
	return E2EFramingScript.encode_json(data)


static func _decode_u32_be(buf: PackedByteArray, offset: int) -> int:
	return (buf[offset] << 24) | (buf[offset + 1] << 16) | (buf[offset + 2] << 8) | buf[offset + 3]


# ---------------------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------------------

func _dispatch(cmd: Dictionary) -> void:
	var action: String = cmd.get("action", "")
	var cmd_id = cmd.get("id", null)

	_log("<< %s (id=%s)" % [action, str(cmd_id)])

	# Handshake must be first.
	if not _authenticated:
		if action != "hello":
			_send_response({"id": cmd_id, "error": "not_authenticated", "message": "First command must be 'hello'"})
			_disconnect_peer()
			return
		_handle_hello(cmd)
		return

	# Delegate to command handler.
	var result: Dictionary = _handler.execute(cmd)

	if result.has("_deferred"):
		_enter_wait(result)
	else:
		_send_response(result)


# ---------------------------------------------------------------------------
# Handshake
# ---------------------------------------------------------------------------

func _handle_hello(cmd: Dictionary) -> void:
	var cmd_id = cmd.get("id", null)
	var token: String = cmd.get("token", "")
	var expected_token := Config.get_token()

	if expected_token != "" and token != expected_token:
		_send_response({"id": cmd_id, "error": "auth_failed", "message": "Token mismatch"})
		_disconnect_peer()
		return

	_authenticated = true
	_ever_authenticated = true
	_orphan_deadline_ms = 0
	var version_info := Engine.get_version_info()
	var godot_version := "%d.%d.%d" % [version_info["major"], version_info["minor"], version_info["patch"]]
	_send_response({
		"id": cmd_id,
		"ok": true,
		"godot_version": godot_version,
		"server_version": SERVER_VERSION,
	})
	_log("authenticated")


# ---------------------------------------------------------------------------
# Wait state management
# ---------------------------------------------------------------------------

func _enter_wait(params: Dictionary) -> void:
	_pending_id = params.get("id", null)
	_state = State.WAITING
	_wait_start_ms = Time.get_ticks_msec()
	# Timeout comes as seconds from command_handler; convert to ms.
	# 0 means no timeout (used for frame waits, second waits, input settle).
	var timeout_sec: float = params.get("timeout", 0.0)
	_wait_timeout_ms = int(timeout_sec * 1000.0)

	var wait_type_str: String = params.get("wait_type", "")
	match wait_type_str:
		"process_frames":
			_wait_type = WaitType.PROCESS_FRAMES
			_wait_process_remaining = params.get("count", 1)
		"physics_frames":
			_wait_type = WaitType.PHYSICS_FRAMES
			_wait_physics_remaining = params.get("count", 1)
		"seconds":
			_wait_type = WaitType.SECONDS
			_wait_seconds_elapsed = 0.0
			_wait_seconds_target = params.get("duration", 1.0)
		"node_exists":
			_wait_type = WaitType.NODE_EXISTS
			_wait_node_path = params.get("path", "")
		"signal":
			_wait_type = WaitType.SIGNAL_EMITTED
			_wait_signal_emitted = false
			var source_path: String = params.get("path", "")
			var sig_name: String = params.get("signal_name", "")
			var source := get_tree().root.get_node_or_null(source_path)
			if source == null:
				_send_response({"id": _pending_id, "error": "node_not_found", "message": "Signal source '%s' not found" % source_path})
				_transition_idle()
				return
			_wait_signal_source = source
			_wait_signal_name = sig_name
			_wait_signal_connection = func(): _wait_signal_emitted = true
			if source.has_signal(sig_name):
				source.connect(sig_name, _wait_signal_connection, CONNECT_ONE_SHOT)
			else:
				_send_response({"id": _pending_id, "error": "signal_not_found", "message": "Signal '%s' not found on '%s'" % [sig_name, source_path]})
				_transition_idle()
				return
		"property":
			_wait_type = WaitType.PROPERTY_VALUE
			_wait_property_node_path = params.get("path", "")
			_wait_property_name = params.get("property", "")
			_wait_property_value = params.get("value")
		"scene_change":
			_wait_type = WaitType.SCENE_CHANGE
			_wait_scene_path = params.get("scene_path", "")
		_:
			_send_response({"id": _pending_id, "error": "unknown_wait_type", "message": "Unknown wait type '%s'" % wait_type_str})
			_transition_idle()


func _poll_wait(delta: float) -> void:
	# Check wall-clock timeout for all wait types.
	if _wait_timeout_ms > 0:
		var elapsed_ms := Time.get_ticks_msec() - _wait_start_ms
		if elapsed_ms >= _wait_timeout_ms:
			_send_response({"id": _pending_id, "error": "timeout", "message": "Wait timed out after %d ms" % _wait_timeout_ms})
			_cleanup_wait()
			_transition_idle()
			return

	match _wait_type:
		WaitType.PROCESS_FRAMES:
			_wait_process_remaining -= 1
			if _wait_process_remaining <= 0:
				_send_response({"id": _pending_id, "ok": true})
				_transition_idle()
		WaitType.SECONDS:
			_wait_seconds_elapsed += delta
			if _wait_seconds_elapsed >= _wait_seconds_target:
				_send_response({"id": _pending_id, "ok": true})
				_transition_idle()
		WaitType.NODE_EXISTS:
			var node := get_tree().root.get_node_or_null(_wait_node_path)
			if node != null:
				_send_response({"id": _pending_id, "ok": true})
				_transition_idle()
		WaitType.SIGNAL_EMITTED:
			if _wait_signal_emitted:
				_send_response({"id": _pending_id, "ok": true})
				_transition_idle()
		WaitType.PROPERTY_VALUE:
			var node := get_tree().root.get_node_or_null(_wait_property_node_path)
			if node != null and node.get(_wait_property_name) == _wait_property_value:
				_send_response({"id": _pending_id, "ok": true})
				_transition_idle()
		WaitType.SCENE_CHANGE:
			var current_scene := get_tree().current_scene
			if current_scene != null:
				var scene_file := current_scene.scene_file_path
				if _wait_scene_path == "" or scene_file == _wait_scene_path:
					_send_response({"id": _pending_id, "ok": true})
					_transition_idle()
		WaitType.PHYSICS_FRAMES:
			# Handled in _physics_process.
			pass


func _transition_idle() -> void:
	_cleanup_wait()
	_state = State.IDLE
	_pending_id = null
	_wait_type = WaitType.NONE


func _cleanup_wait() -> void:
	# Disconnect any pending signal connections.
	if _wait_type == WaitType.SIGNAL_EMITTED and _wait_signal_source != null:
		if not _wait_signal_emitted and _wait_signal_source.is_connected(_wait_signal_name, _wait_signal_connection):
			_wait_signal_source.disconnect(_wait_signal_name, _wait_signal_connection)
		_wait_signal_source = null
		_wait_signal_connection = Callable()
		_wait_signal_name = ""


# ---------------------------------------------------------------------------
# Disconnect / reset
# ---------------------------------------------------------------------------

func _disconnect_peer() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	_state = State.DISCONNECTED


func _handle_disconnect() -> void:
	var was_authenticated := _authenticated
	_cleanup_wait()
	_peer = null
	_recv_buffer = PackedByteArray()
	_authenticated = false
	_pending_id = null
	_wait_type = WaitType.NONE
	_last_drain_seq = -1
	if was_authenticated and _ever_authenticated:
		_orphan_deadline_ms = Time.get_ticks_msec() + int(E2EProtocolScript.ORPHAN_GRACE_SECONDS * 1000.0)
	_state = State.LISTENING
	_log("reset to LISTENING")


# ---------------------------------------------------------------------------
# Log capture controls (called by command_handler — keeps the handler
# off _log_capture's private surface)
# ---------------------------------------------------------------------------

func has_log_capture() -> bool:
	return _log_capture != null


func set_log_verbosity(level: String) -> bool:
	if _log_capture == null:
		return false
	return _log_capture.set_verbosity_str(level)


func set_log_buffer_size(size: int) -> bool:
	if _log_capture == null:
		return false
	if size < 1:
		return false
	_log_capture.set_max_size(size)
	return true


func _write_port_file(path: String, port: int) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("godot-e2e: failed to write port file '%s' (error %d)" % [path, FileAccess.get_open_error()])
		return
	file.store_string(str(port))
	file.close()
	_log("wrote port %d to '%s'" % [port, path])


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

func _log(msg: String) -> void:
	if Config.is_logging():
		print("[godot-e2e] %s" % msg)
