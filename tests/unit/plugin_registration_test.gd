extends GdUnitTestSuite

func test_plugin_script_entrypoint() -> void:
	var cfg := ConfigFile.new()
	assert_int(cfg.load("res://addons/gdunit_e2e/plugin.cfg")).is_equal(OK)
	assert_str(cfg.get_value("plugin", "script")).is_equal("plugin.gd")

func test_root_project_has_runtime_autoload() -> void:
	assert_str(ProjectSettings.get_setting("autoload/GdUnitE2EAutomationServer", "")).contains(
		"res://addons/gdunit_e2e/server/automation_server.gd"
	)
