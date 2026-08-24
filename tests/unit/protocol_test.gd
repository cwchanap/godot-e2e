extends GdUnitTestSuite


func test_encode_json_uses_big_endian_length_and_utf8_payload() -> void:
	var message := {"id": 7, "text": "hé 🌍"}
	var payload := JSON.stringify(message).to_utf8_buffer()
	var encoded := E2EFraming.encode_json(message)

	assert_int(encoded.size()).is_equal(payload.size() + 4)
	assert_int(encoded[0]).is_equal((payload.size() >> 24) & 0xff)
	assert_int(encoded[1]).is_equal((payload.size() >> 16) & 0xff)
	assert_int(encoded[2]).is_equal((payload.size() >> 8) & 0xff)
	assert_int(encoded[3]).is_equal(payload.size() & 0xff)
	assert_that(encoded.slice(4).get_string_from_utf8()).is_equal(JSON.stringify(message))


func test_try_extract_waits_for_a_partial_header() -> void:
	var frame := E2EFraming.encode_json({"id": 1})

	for byte_count in range(4):
		var result := E2EFraming.try_extract(frame.slice(0, byte_count))
		assert_bool(result.get("complete", false)).is_false()


func test_try_extract_waits_for_a_partial_body() -> void:
	var frame := E2EFraming.encode_json({"id": 1, "value": "payload"})
	var result := E2EFraming.try_extract(frame.slice(0, frame.size() - 1))

	assert_bool(result.get("complete", false)).is_false()


func test_try_extract_returns_message_and_consumed_bytes() -> void:
	var frame := E2EFraming.encode_json({"id": 1, "value": "payload"})
	var result := E2EFraming.try_extract(frame)

	assert_bool(result.get("complete", false)).is_true()
	assert_that(result.get("message")).is_equal({"id": 1.0, "value": "payload"})
	assert_int(result.get("consumed_bytes", -1)).is_equal(frame.size())


func test_try_extract_handles_two_concatenated_frames() -> void:
	var first := E2EFraming.encode_json({"id": 1})
	var second := E2EFraming.encode_json({"id": 2})
	var stream := first
	stream.append_array(second)

	var first_result := E2EFraming.try_extract(stream)
	assert_bool(first_result.get("complete", false)).is_true()
	assert_that(first_result.get("message")).is_equal({"id": 1.0})

	var second_result := E2EFraming.try_extract(stream.slice(first_result["consumed_bytes"]))
	assert_bool(second_result.get("complete", false)).is_true()
	assert_that(second_result.get("message")).is_equal({"id": 2.0})


func test_try_extract_accepts_a_frame_at_the_16_mib_boundary() -> void:
	var prefix := '{"blob":"'
	var suffix := '"}'
	var blob_size := E2EProtocol.MAX_FRAME_BYTES - prefix.to_utf8_buffer().size() - suffix.to_utf8_buffer().size()
	var payload := (prefix + "x".repeat(blob_size) + suffix).to_utf8_buffer()
	var frame := _with_length_prefix(payload)

	assert_int(payload.size()).is_equal(E2EProtocol.MAX_FRAME_BYTES)
	var result := E2EFraming.try_extract(frame)
	assert_bool(result.get("complete", false)).is_true()
	var message: Dictionary = result.get("message", {})
	assert_bool(message.has("blob")).is_true()


func test_try_extract_rejects_an_oversized_declared_length_before_body() -> void:
	var header_only := PackedByteArray([
		((E2EProtocol.MAX_FRAME_BYTES + 1) >> 24) & 0xff,
		((E2EProtocol.MAX_FRAME_BYTES + 1) >> 16) & 0xff,
		((E2EProtocol.MAX_FRAME_BYTES + 1) >> 8) & 0xff,
		(E2EProtocol.MAX_FRAME_BYTES + 1) & 0xff,
	])
	var result := E2EFraming.try_extract(header_only)

	assert_bool(result.get("complete", false)).is_false()
	assert_str(result.get("error", "")).is_equal("frame_too_large")
	assert_int(result.get("declared_size", -1)).is_equal(E2EProtocol.MAX_FRAME_BYTES + 1)


func _with_length_prefix(payload: PackedByteArray) -> PackedByteArray:
	var frame := PackedByteArray()
	frame.resize(4)
	frame[0] = (payload.size() >> 24) & 0xff
	frame[1] = (payload.size() >> 16) & 0xff
	frame[2] = (payload.size() >> 8) & 0xff
	frame[3] = payload.size() & 0xff
	frame.append_array(payload)
	return frame
