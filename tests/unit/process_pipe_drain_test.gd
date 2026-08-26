extends GdUnitTestSuite

const E2EProcessScript = preload("res://addons/gdunit_e2e/client/e2e_process.gd")

var _process = null


class _OsBufferPipe:
	var cap := 4
	var remaining := 0
	var buffered := 0
	var empty_peeks := 0

	func is_open() -> bool:
		return true

	func get_length() -> int:
		if buffered > 0:
			empty_peeks = 0
			return buffered
		empty_peeks += 1
		# One empty peek ends the current non-blocking snapshot. The next peek
		# is the producer filling the OS buffer after the previous write unblocked.
		if empty_peeks >= 2 and remaining > 0:
			var refill: int = mini(cap, remaining)
			buffered = refill
			remaining -= refill
			empty_peeks = 0
			return buffered
		return 0

	func get_buffer(size: int) -> PackedByteArray:
		var n: int = mini(size, buffered)
		buffered -= n
		var bytes := PackedByteArray()
		bytes.resize(n)
		bytes.fill("x".unicode_at(0))
		return bytes


func after_test() -> void:
	if is_instance_valid(_process):
		_process.queue_free()
		_process = null


# A child that writes faster than the parent frame rate fills a small OS pipe
# buffer, blocks, then continues only after the parent reads. A single
# available-bytes snapshot therefore sees one buffer's worth and then 0, even
# though more data is still coming. Live drain must keep reading across that
# empty gap so one tick can empty a burst larger than the OS buffer.
func test_live_pipe_drain_keeps_reading_across_os_buffer_empty_gaps() -> void:
	_process = E2EProcessScript.new(self)
	add_child(_process)
	var pipe := _OsBufferPipe.new()
	pipe.cap = 4
	pipe.buffered = 4
	pipe.remaining = 8
	_process._stdio = pipe

	_process._drain_pipes_live()

	assert_int(_process.get_stdout().length()).is_equal(12)
