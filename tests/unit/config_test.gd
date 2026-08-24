extends GdUnitTestSuite

const Config = preload("res://addons/gdunit_e2e/server/config.gd")


func after_test() -> void:
	Config._reset_for_testing()


func test_configuration_is_disabled_without_the_e2e_flag() -> void:
	Config._reset_for_testing([])

	assert_bool(Config.is_enabled()).is_false()
	assert_bool(Config.is_valid()).is_true()


func test_configuration_reads_the_gdunit_e2e_flags() -> void:
	Config._reset_for_testing([
		"--gdunit-e2e",
		"--gdunit-e2e-port=0",
		"--gdunit-e2e-port-file=/tmp/gdunit-e2e-port",
		"--gdunit-e2e-token=secret",
		"--gdunit-e2e-log-verbosity=info",
	])

	assert_bool(Config.is_enabled()).is_true()
	assert_bool(Config.is_valid()).is_true()
	assert_int(Config.get_port()).is_equal(0)
	assert_str(Config.get_port_file()).is_equal("/tmp/gdunit-e2e-port")
	assert_str(Config.get_token()).is_equal("secret")
	assert_str(Config.get_log_verbosity()).is_equal("info")


func test_non_integer_port_is_invalid_without_falling_back() -> void:
	Config._reset_for_testing(["--gdunit-e2e", "--gdunit-e2e-port=abc"])

	assert_bool(Config.is_enabled()).is_true()
	assert_bool(Config.is_valid()).is_false()
	assert_str(Config.get_validation_error()).contains("port")
	assert_int(Config.get_port()).is_equal(-1)


func test_out_of_range_port_is_invalid_without_falling_back() -> void:
	Config._reset_for_testing(["--gdunit-e2e", "--gdunit-e2e-port=70000"])

	assert_bool(Config.is_valid()).is_false()
	assert_str(Config.get_validation_error()).contains("70000")
	assert_int(Config.get_port()).is_equal(-1)


func test_ephemeral_port_requires_a_port_file() -> void:
	Config._reset_for_testing(["--gdunit-e2e", "--gdunit-e2e-port=0"])

	assert_bool(Config.is_valid()).is_false()
	assert_str(Config.get_validation_error()).contains("port-file")


func test_unknown_log_verbosity_is_invalid_without_falling_back() -> void:
	Config._reset_for_testing(["--gdunit-e2e", "--gdunit-e2e-log-verbosity=verbose"])

	assert_bool(Config.is_valid()).is_false()
	assert_str(Config.get_validation_error()).contains("verbose")
	assert_str(Config.get_log_verbosity()).is_equal("verbose")
