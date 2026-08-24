class_name E2EFraming


static func encode_json(message: Dictionary) -> PackedByteArray:
	var payload := JSON.stringify(message).to_utf8_buffer()
	if payload.size() > E2EProtocol.MAX_FRAME_BYTES:
		push_error("E2E frame exceeds the 16 MiB limit")
		return PackedByteArray()

	var frame := PackedByteArray()
	frame.resize(4)
	frame[0] = (payload.size() >> 24) & 0xff
	frame[1] = (payload.size() >> 16) & 0xff
	frame[2] = (payload.size() >> 8) & 0xff
	frame[3] = payload.size() & 0xff
	frame.append_array(payload)
	return frame


static func try_extract(buffer: PackedByteArray) -> Dictionary:
	if buffer.size() < 4:
		return {"complete": false}

	var declared_size := _decode_u32_be(buffer, 0)
	if declared_size > E2EProtocol.MAX_FRAME_BYTES:
		return {
			"complete": false,
			"error": "frame_too_large",
			"declared_size": declared_size,
		}

	var frame_size := 4 + declared_size
	if buffer.size() < frame_size:
		return {"complete": false}

	var payload := buffer.slice(4, frame_size)
	var json_text := payload.get_string_from_utf8()
	var parsed = JSON.parse_string(json_text)
	if parsed == null:
		return {
			"complete": true,
			"consumed_bytes": frame_size,
			"error": "invalid_json",
		}
	if not parsed is Dictionary:
		return {
			"complete": true,
			"consumed_bytes": frame_size,
			"error": "invalid_message",
		}

	return {
		"complete": true,
		"consumed_bytes": frame_size,
		"message": parsed,
	}


static func _decode_u32_be(buffer: PackedByteArray, offset: int) -> int:
	return (buffer[offset] << 24) | (buffer[offset + 1] << 16) | (buffer[offset + 2] << 8) | buffer[offset + 3]
