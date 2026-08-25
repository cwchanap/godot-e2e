extends GdUnitTestSuite


func test_project_has_no_e2e_autoload() -> void:
    assert_bool(
        ProjectSettings.has_setting("autoload/GdUnitE2EAutomationServer")
    ).is_false()


func test_addon_requires_no_editor_plugin() -> void:
    assert_bool(FileAccess.file_exists(
        "res://addons/gdunit_e2e/plugin.cfg"
    )).is_false()
    assert_bool(FileAccess.file_exists(
        "res://addons/gdunit_e2e/plugin.gd"
    )).is_false()


func test_bootstrap_scene_points_to_bootstrap_script() -> void:
    var packed := load("res://addons/gdunit_e2e/runtime/bootstrap.tscn") as PackedScene
    assert_object(packed).is_not_null()
    var root := packed.instantiate()
    assert_str(root.get_script().resource_path).is_equal(
        "res://addons/gdunit_e2e/runtime/bootstrap.gd"
    )
    root.free()
