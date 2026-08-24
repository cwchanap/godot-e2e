class_name E2EResult
extends RefCounted

var ok: bool
var value: Variant
var message: String
var logs: Array


func _init(
	result_ok: bool = false,
	result_value: Variant = null,
	result_message: String = "",
	result_logs: Array = [],
) -> void:
	ok = result_ok
	value = result_value
	message = result_message
	logs = result_logs
