class_name E2EProcess
extends Node

const E2EClientScript = preload("e2e_client.gd")
const E2EResultScript = preload("e2e_result.gd")
const BootstrapScene = preload("../runtime/bootstrap.tscn")

const POLL_INTERVAL_MILLIS := 25
const SHUTDOWN_GRACE_MILLIS := 1000
const PIPE_DRAIN_MILLIS := 500
const MAX_PIPE_BYTES := 4 * 1024 * 1024

var _suite: GdUnitTestSuite
var _process_info: Dictionary = {}
var _pid := -1
var _exit_code := -1
var _stdio = null
var _stderr = null
var _client = null
var _port_file := ""
var _token := ""
var _port := -1
var _stdout_text := ""
var _stderr_text := ""
var _close_error := ""
var _close_started := false
var _close_complete := false
var _dead_confirmed := false


func _init(suite: GdUnitTestSuite) -> void:
	_suite = suite


static func build_arguments(options: E2ELaunchOptions, port_file: String, token: String) -> PackedStringArray:
	var args := PackedStringArray([
		"--path",
		options.project_path,
		"--scene",
		BootstrapScene.resource_path,
	])
	for extra_arg in options.extra_godot_args:
		args.append(String(extra_arg))
	args.append("--")
	args.append("--gdunit-e2e")
	args.append("--gdunit-e2e-target-scene=" + options.scene_path)
	args.append("--gdunit-e2e-port=" + str(options.server_port))
	args.append("--gdunit-e2e-port-file=" + port_file)
	args.append("--gdunit-e2e-token=" + token)
	args.append("--gdunit-e2e-log-verbosity=" + options.log_verbosity)
	return args


func launch(options: E2ELaunchOptions) -> E2EResult:
	if options == null:
		return _failure("Launch options are required")
	if not is_inside_tree():
		return _failure("E2EProcess must be inside the SceneTree before launching")
	if not is_instance_valid(_suite) or not _suite.is_inside_tree():
		return _failure("E2EProcess requires an owning GdUnitTestSuite in the SceneTree")
	if _pid > 0 or _client != null:
		await close()

	var project_path: String = options.project_path
	if project_path.is_empty():
		project_path = ProjectSettings.globalize_path("res://")
	if not _is_same_project(project_path):
		return _failure("E2E child project must be the current in-tree project: %s" % project_path)
	project_path = project_path.simplify_path()

	var executable: String = options.godot_path
	if executable.is_empty():
		executable = _default_godot_path()
	if not FileAccess.file_exists(executable):
		return _failure("Godot executable does not exist: %s" % executable)

	_token = _new_token()
	var temp_dir := _suite.create_temp_dir("gdunit_e2e")
	_port_file = temp_dir + "/port_%s.txt" % _token
	var child_options := E2ELaunchOptions.new()
	child_options.project_path = project_path
	child_options.scene_path = options.scene_path
	child_options.godot_path = options.godot_path
	child_options.timeout_seconds = options.timeout_seconds
	child_options.extra_godot_args = options.extra_godot_args
	child_options.log_verbosity = options.log_verbosity
	child_options.server_port = options.server_port
	var args := build_arguments(child_options, _port_file, _token)

	# Own the client before any asynchronous launch polling. This keeps the
	# process and its client under the same SceneTree owner for the complete
	# lifetime of the launch, including failures before the port is available.
	_client = E2EClientScript.new()
	add_child(_client)

	# The child pipes remain untouched while it is alive. Reading them here can
	# block on platform-specific pipe behavior and can deadlock cleanup.
	_process_info = OS.execute_with_pipe(executable, args, false)
	if _process_info.is_empty() or not _process_info.has("pid"):
		await close()
		return _failure("Failed to launch Godot child")
	_pid = int(_process_info.get("pid", -1))
	_stdio = _process_info.get("stdio", null)
	_stderr = _process_info.get("stderr", null)
	_exit_code = -1
	_stdout_text = ""
	_stderr_text = ""
	_close_error = ""
	_close_started = false
	_close_complete = false
	_dead_confirmed = false

	var deadline: int = Time.get_ticks_msec() + max(1, int(options.timeout_seconds * 1000.0))
	while Time.get_ticks_msec() < deadline:
		if not is_running():
			_record_exit_code()
			var exited_message := "Godot child exited before writing its port file (exit %d)" % _exit_code
			await close()
			return _failure(exited_message)
		if FileAccess.file_exists(_port_file):
			var raw_port := FileAccess.get_file_as_string(_port_file).strip_edges()
			if raw_port.is_valid_int():
				var parsed_port := raw_port.to_int()
				if parsed_port > 0 and parsed_port <= 65535:
					_port = parsed_port
					break
		await _suite.await_millis(POLL_INTERVAL_MILLIS)

	if _port <= 0:
		await close()
		return _failure("Timed out waiting for the child E2E server port file")

	var connect_result = await _client.connect_to_server(_port, _token, options.timeout_seconds)
	if not connect_result.ok:
		var message := "Child E2E handshake failed: %s" % connect_result.message
		await close()
		return _failure(message)
	return connect_result


func close() -> void:
	if _close_complete or _close_started:
		return
	_close_started = true
	_close_error = ""

	var client = _client
	if is_instance_valid(client):
		if client.is_session_open():
			# Quit is best effort. A child can disappear before its response is
			# observed, and the bounded reap below is the source of truth.
			await client.send_command("quit", {}, 0.5)
		client.close()
		client.queue_free()
		_client = null

	var death_observed := _pid <= 0
	if _pid > 0:
		death_observed = await _wait_for_death(SHUTDOWN_GRACE_MILLIS)
		if not death_observed:
			death_observed = await _force_kill()
	if not death_observed or (_pid > 0 and not _dead_confirmed):
		_close_error = "Unable to confirm Godot child PID %d exited" % _pid
		_close_started = false
		return
	_record_exit_code()
	await _drain_pipes()
	_remove_port_file()
	_close_complete = true
	_close_started = false


func is_running() -> bool:
	if _pid <= 0 or _dead_confirmed:
		return false
	# Fetch the exit status before asking Godot whether the process is running.
	# On Unix, is_process_running() may reap an exited child without retaining
	# the status, which would make the later exit-code query noisy and useless.
	var process_exit_code := OS.get_process_exit_code(_pid)
	if process_exit_code >= 0:
		_exit_code = process_exit_code
		_dead_confirmed = true
		return false
	var running := OS.is_process_running(_pid)
	if not running:
		_dead_confirmed = true
	return running


func get_client() -> E2EClient:
	return _client


func get_stdout() -> String:
	return _stdout_text


func get_stderr() -> String:
	return _stderr_text


func get_exit_code() -> int:
	_record_exit_code()
	return _exit_code


func get_close_error() -> String:
	return _close_error


func get_port() -> int:
	return _port


func get_pid() -> int:
	return _pid


func get_port_file() -> String:
	return _port_file


func _default_godot_path() -> String:
	var configured := OS.get_environment("GODOT_BIN")
	return configured if not configured.is_empty() else OS.get_executable_path()


func _is_same_project(path: String) -> bool:
	var expected := ProjectSettings.globalize_path("res://").simplify_path()
	var candidate := path
	if candidate.begins_with("res://"):
		candidate = ProjectSettings.globalize_path(candidate)
	candidate = candidate.simplify_path()
	if OS.get_name() == "Windows":
		return candidate.to_lower() == expected.to_lower()
	return candidate == expected


func _new_token() -> String:
	var entropy := OS.get_entropy(16).hex_encode()
	return "%s-%s" % [entropy, str(get_instance_id())]


func _failure(message: String) -> E2EResult:
	return E2EResultScript.new(false, null, message)


func _wait_for_death(timeout_millis: int) -> bool:
	if _pid <= 0:
		return false
	var deadline := Time.get_ticks_msec() + timeout_millis
	while is_running() and Time.get_ticks_msec() < deadline:
		await _wait_millis(POLL_INTERVAL_MILLIS)
	return _dead_confirmed


func _force_kill() -> bool:
	if _pid <= 0:
		return false
	var deadline := Time.get_ticks_msec() + SHUTDOWN_GRACE_MILLIS
	while is_running() and Time.get_ticks_msec() < deadline:
		OS.kill(_pid)
		await _wait_millis(POLL_INTERVAL_MILLIS)
	if is_running():
		OS.kill(_pid)
		await _wait_for_death(POLL_INTERVAL_MILLIS * 4)
	return _dead_confirmed


func _wait_millis(millis: int) -> void:
	if is_instance_valid(_suite):
		await _suite.await_millis(millis)


func _record_exit_code() -> void:
	if _exit_code != -1:
		return
	if _pid > 0 and not _dead_confirmed:
		is_running()


func _drain_pipes() -> void:
	_stdout_text = await _drain_pipe(_stdio)
	_stderr_text = await _drain_pipe(_stderr)
	_close_pipe(_stdio)
	_close_pipe(_stderr)
	_stdio = null
	_stderr = null


func _drain_pipe(pipe) -> String:
	if pipe == null or not pipe.is_open():
		return ""
	var bytes := PackedByteArray()
	var deadline := Time.get_ticks_msec() + PIPE_DRAIN_MILLIS
	var empty_polls := 0
	while Time.get_ticks_msec() < deadline and bytes.size() < MAX_PIPE_BYTES:
		var available := int(pipe.get_length())
		if available > 0:
			var read_size := min(available, MAX_PIPE_BYTES - bytes.size())
			bytes.append_array(pipe.get_buffer(read_size))
			empty_polls = 0
			continue
		if pipe.get_error() != OK or pipe.eof_reached() or empty_polls >= 2:
			break
		empty_polls += 1
		await _wait_millis(POLL_INTERVAL_MILLIS)
	return bytes.get_string_from_utf8()


func _close_pipe(pipe) -> void:
	if pipe != null and pipe.is_open():
		pipe.close()


func _remove_port_file() -> void:
	if _port_file.is_empty():
		return
	var absolute_path := ProjectSettings.globalize_path(_port_file)
	if FileAccess.file_exists(absolute_path):
		DirAccess.remove_absolute(absolute_path)
