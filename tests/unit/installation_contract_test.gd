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


func test_bootstrap_scene_script_is_uid_backed() -> void:
    var scene_text := FileAccess.get_file_as_string(
        "res://addons/gdunit_e2e/runtime/bootstrap.tscn"
    )
    var script_ext_resource_line := ""
    for line in scene_text.split("\n"):
        if line.contains("[ext_resource") and line.contains(
            'path="res://addons/gdunit_e2e/runtime/bootstrap.gd"'
        ):
            script_ext_resource_line = line
            break

    assert_bool(script_ext_resource_line.contains('uid="uid://')).is_true()
    var uid_start := script_ext_resource_line.find('uid="') + 5
    var uid_end := script_ext_resource_line.find('"', uid_start)
    var uid := script_ext_resource_line.substr(uid_start, uid_end - uid_start)
    assert_bool(
        ResourceUID.get_id_path(ResourceUID.text_to_id(uid))
        == "res://addons/gdunit_e2e/runtime/bootstrap.gd"
    ).is_true()
    assert_bool(FileAccess.file_exists(
        "res://addons/gdunit_e2e/runtime/bootstrap.gd.uid"
    )).is_true()
