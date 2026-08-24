extends GdUnitTestSuite

const AutomationServer = preload("res://addons/gdunit_e2e/server/automation_server.gd")
const Protocol = preload("res://addons/gdunit_e2e/protocol/e2e_protocol.gd")

var _automation_server


func after_test() -> void:
	if is_instance_valid(_automation_server):
		_automation_server.queue_free()
	_automation_server = null


func test_oversized_declaration_is_rejected_before_body_read() -> void:
	var peer := _BufferedPeer.new()
	_automation_server = AutomationServer.new()
	_automation_server._peer = peer
	_automation_server._state = 1 # State.IDLE

	var declared_size := Protocol.MAX_FRAME_BYTES + 1
	var malicious := PackedByteArray()
	malicious.resize(4 + 32)
	malicious[0] = (declared_size >> 24) & 0xff
	malicious[1] = (declared_size >> 16) & 0xff
	malicious[2] = (declared_size >> 8) & 0xff
	malicious[3] = declared_size & 0xff
	for index in range(4, malicious.size()):
		malicious[index] = 0x78
	peer.incoming = malicious
	_automation_server._poll_recv()

	assert_int(_automation_server._recv_buffer.size()).is_equal(4)
	assert_that(peer.read_sizes).is_equal([4])
	assert_int(peer.incoming.size()).is_equal(32)
	assert_bool(peer.disconnected).is_true()


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
