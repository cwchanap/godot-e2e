## Command-line configuration parser for the GdUnit E2E child server.
##
## Parses arguments passed after the `--` separator via OS.get_cmdline_user_args().
## Usage:
##   var cfg = preload("config.gd")
##   cfg.is_enabled()           # --gdunit-e2e flag present?
##   cfg.get_port()             # --gdunit-e2e-port=N (0 = auto)
##   cfg.get_port_file()        # --gdunit-e2e-port-file=PATH
##   cfg.get_token()             # --gdunit-e2e-token=X
##   cfg.get_log_verbosity()    # --gdunit-e2e-log-verbosity={error|warning|info}
##
## Modified from RandallLiuXin/godot-e2e at pinned upstream source commit
## ae6219f6e758a0f29bd243c8f963417fe4d63c36. The pinned upstream source is
## under Apache-2.0. The addon uses renamed flags and fails closed for
## malformed E2E-only configuration.

class_name GdUnitE2EConfig

const DEFAULT_PORT: int = 6008
const DEFAULT_LOG_VERBOSITY: String = "warning"
const _VALID_VERBOSITIES: Array = ["error", "warning", "info"]

static var _parsed: bool = false
static var _enabled: bool = false
static var _port: int = DEFAULT_PORT
static var _token: String = ""
static var _port_file: String = ""
static var _target_scene := ""
static var _log_verbosity: String = DEFAULT_LOG_VERBOSITY
static var _valid: bool = true
static var _validation_error: String = ""
static var _test_args: Array = []
static var _has_test_args: bool = false


static func _ensure_parsed() -> void:
	if _parsed:
		return
	_parsed = true

	var args = _test_args if _has_test_args else OS.get_cmdline_user_args()
	for arg in args:
		if arg == "--gdunit-e2e":
			_enabled = true
		elif arg.begins_with("--gdunit-e2e-port="):
			var value: String = arg.substr("--gdunit-e2e-port=".length())
			if value.is_valid_int():
				_port = value.to_int()
				if _port < 0 or _port > 65535:
					_mark_invalid("invalid port value '%s' (expected 0..65535)" % value)
					_port = -1
			else:
				_mark_invalid("invalid port value '%s'" % value)
				_port = -1
		elif arg.begins_with("--gdunit-e2e-token="):
			_token = arg.substr("--gdunit-e2e-token=".length())
		elif arg.begins_with("--gdunit-e2e-port-file="):
			_port_file = arg.substr("--gdunit-e2e-port-file=".length())
		elif arg.begins_with("--gdunit-e2e-log-verbosity="):
			var value: String = arg.substr("--gdunit-e2e-log-verbosity=".length())
			if value in _VALID_VERBOSITIES:
				_log_verbosity = value
			else:
				_mark_invalid("invalid log verbosity '%s' (expected error, warning, or info)" % value)
				_log_verbosity = value
		elif arg.begins_with("--gdunit-e2e-target-scene="):
			_target_scene = arg.substr("--gdunit-e2e-target-scene=".length())
			if _target_scene.is_empty():
				_mark_invalid("target scene must not be empty")
		elif arg.begins_with("--gdunit-e2e"):
			_mark_invalid("unknown or malformed flag '%s'" % arg)

	if _port == 0 and _port_file.is_empty():
		_mark_invalid("port 0 requires --gdunit-e2e-port-file")


static func _mark_invalid(message: String) -> void:
	_valid = false
	if _validation_error.is_empty():
		_validation_error = message
	else:
		_validation_error += "; " + message


static func is_enabled() -> bool:
	_ensure_parsed()
	return _enabled


static func is_valid() -> bool:
	_ensure_parsed()
	return _valid


static func get_validation_error() -> String:
	_ensure_parsed()
	return _validation_error


static func get_port() -> int:
	_ensure_parsed()
	return _port


static func get_token() -> String:
	_ensure_parsed()
	return _token


static func get_port_file() -> String:
	_ensure_parsed()
	return _port_file


static func get_target_scene() -> String:
	_ensure_parsed()
	return _target_scene


static func is_logging() -> bool:
	_ensure_parsed()
	return _enabled and _log_verbosity == "info"


static func get_log_verbosity() -> String:
	_ensure_parsed()
	return _log_verbosity


## Test-only parser reset. Runtime callers always use OS.get_cmdline_user_args().
static func _reset_for_testing(args: Array = []) -> void:
	_test_args = args
	_has_test_args = true
	_parsed = false
	_enabled = false
	_port = DEFAULT_PORT
	_token = ""
	_port_file = ""
	_target_scene = ""
	_log_verbosity = DEFAULT_LOG_VERBOSITY
	_valid = true
	_validation_error = ""
