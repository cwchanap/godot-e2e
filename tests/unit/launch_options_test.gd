extends GdUnitTestSuite

const LaunchOptions = preload("res://addons/gdunit_e2e/client/e2e_launch_options.gd")
const E2EProcessScript = preload("res://addons/gdunit_e2e/client/e2e_process.gd")


func test_launch_options_keep_the_required_defaults() -> void:
	var options = LaunchOptions.new()

	assert_str(options.scene_path).is_equal("res://tests/fixtures/minimal/main.tscn")
	assert_float(options.timeout_seconds).is_equal(10.0)
	assert_str(options.log_verbosity).is_equal("warning")
	assert_array(options.extra_godot_args).is_empty()


func test_process_builds_pinned_argv_with_user_separator_last() -> void:
	var options = LaunchOptions.new()
	options.project_path = "/workspace/project"
	options.scene_path = "res://tests/fixtures/minimal/main.tscn"
	options.extra_godot_args = PackedStringArray(["--headless", "--quiet"])
	options.log_verbosity = "warning"

	var token := "token-123"
	var port_file := "user://tmp/process/port_token-123.txt"
	var args: PackedStringArray = E2EProcessScript.build_arguments(options, port_file, token)

	assert_that(args).is_equal(PackedStringArray([
		"--path",
		"/workspace/project",
		"--scene",
		"res://tests/fixtures/minimal/main.tscn",
		"--headless",
		"--quiet",
		"--",
		"--gdunit-e2e",
		"--gdunit-e2e-port=0",
		"--gdunit-e2e-port-file=user://tmp/process/port_token-123.txt",
		"--gdunit-e2e-token=token-123",
		"--gdunit-e2e-log-verbosity=warning",
	]))
	assert_int(args.find("--")).is_equal(6)
	for user_arg in args.slice(args.find("--") + 1):
		assert_bool(String(user_arg).begins_with("--gdunit-e2e")).is_true()
