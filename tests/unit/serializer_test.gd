extends GdUnitTestSuite


func test_serialize_preserves_json_primitives_and_string_name() -> void:
	assert_that(E2ESerializer.serialize(null)).is_null()
	assert_bool(E2ESerializer.serialize(true)).is_true()
	assert_int(E2ESerializer.serialize(42)).is_equal(42)
	assert_float(E2ESerializer.serialize(2.5)).is_equal(2.5)
	assert_str(E2ESerializer.serialize("hello")).is_equal("hello")
	assert_str(E2ESerializer.serialize(&"named")).is_equal("named")


func test_serialize_uses_upstream_vector_and_rect_tags() -> void:
	assert_that(E2ESerializer.serialize(Vector2(1.5, -2.0))).is_equal(
		{"_t": "v2", "x": 1.5, "y": -2.0}
	)
	assert_that(E2ESerializer.serialize(Vector2i(3, -4))).is_equal(
		{"_t": "v2i", "x": 3, "y": -4}
	)
	assert_that(E2ESerializer.serialize(Vector3(1.5, -2.0, 3.25))).is_equal(
		{"_t": "v3", "x": 1.5, "y": -2.0, "z": 3.25}
	)
	assert_that(E2ESerializer.serialize(Vector3i(3, -4, 5))).is_equal(
		{"_t": "v3i", "x": 3, "y": -4, "z": 5}
	)
	assert_that(E2ESerializer.serialize(Rect2(Vector2(1.5, -2.0), Vector2(3.25, 4.5)))).is_equal(
		{"_t": "r2", "x": 1.5, "y": -2.0, "w": 3.25, "h": 4.5}
	)
	assert_that(E2ESerializer.serialize(Rect2i(Vector2i(1, -2), Vector2i(3, 4)))).is_equal(
		{"_t": "r2i", "x": 1, "y": -2, "w": 3, "h": 4}
	)


func test_serialize_uses_upstream_color_transform_and_node_path_tags() -> void:
	var serialized_color: Dictionary = E2ESerializer.serialize(Color(0.1, 0.2, 0.3, 0.4))
	assert_str(serialized_color.get("_t", "")).is_equal("col")
	assert_float(serialized_color.get("r", 0.0)).is_equal_approx(0.1, 0.0001)
	assert_float(serialized_color.get("g", 0.0)).is_equal_approx(0.2, 0.0001)
	assert_float(serialized_color.get("b", 0.0)).is_equal_approx(0.3, 0.0001)
	assert_float(serialized_color.get("a", 0.0)).is_equal_approx(0.4, 0.0001)
	assert_that(E2ESerializer.serialize(Transform2D(Vector2(1, 2), Vector2(3, 4), Vector2(5, 6)))).is_equal(
		{
			"_t": "t2d",
			"x": {"_t": "v2", "x": 1.0, "y": 2.0},
			"y": {"_t": "v2", "x": 3.0, "y": 4.0},
			"o": {"_t": "v2", "x": 5.0, "y": 6.0},
		}
	)
	assert_that(E2ESerializer.serialize(NodePath("root/player"))).is_equal(
		{"_t": "np", "v": "root/player"}
	)


func test_serialize_recurses_through_arrays_and_stringifies_dictionary_keys() -> void:
	var value := [Vector2.ONE, {2: Vector3i(3, 4, 5), "nested": [Color.RED]}]

	assert_that(E2ESerializer.serialize(value)).is_equal([
		{"_t": "v2", "x": 1.0, "y": 1.0},
		{
			"2": {"_t": "v3i", "x": 3, "y": 4, "z": 5},
			"nested": [{"_t": "col", "r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0}],
		},
	])


func test_serialize_supports_upstream_packed_arrays() -> void:
	assert_that(E2ESerializer.serialize(PackedVector2Array([Vector2(1, 2), Vector2(3, 4)]))).is_equal([
		{"_t": "v2", "x": 1.0, "y": 2.0},
		{"_t": "v2", "x": 3.0, "y": 4.0},
	])
	assert_that(E2ESerializer.serialize(PackedFloat32Array([1.5, 2.5]))).is_equal([1.5, 2.5])
	assert_that(E2ESerializer.serialize(PackedInt32Array([1, -2]))).is_equal([1, -2])
	assert_that(E2ESerializer.serialize(PackedStringArray(["one", "two"]))).is_equal(["one", "two"])


func test_serialize_marks_unsupported_values_as_unknown() -> void:
	var value := Vector4(1, 2, 3, 4)
	var serialized: Dictionary = E2ESerializer.serialize(value)

	assert_str(serialized.get("_t", "")).is_equal("_unknown")
	assert_str(serialized.get("_class", "")).is_equal("Vector4")
	assert_str(serialized.get("_str", "")).is_equal(str(value))


func test_deserialize_reconstructs_upstream_tags() -> void:
	assert_that(E2ESerializer.deserialize({"_t": "v2", "x": 1.5, "y": -2.0})).is_equal(Vector2(1.5, -2.0))
	assert_that(E2ESerializer.deserialize({"_t": "v2i", "x": 3, "y": -4})).is_equal(Vector2i(3, -4))
	assert_that(E2ESerializer.deserialize({"_t": "v3", "x": 1.5, "y": -2.0, "z": 3.25})).is_equal(Vector3(1.5, -2.0, 3.25))
	assert_that(E2ESerializer.deserialize({"_t": "v3i", "x": 3, "y": -4, "z": 5})).is_equal(Vector3i(3, -4, 5))
	assert_that(E2ESerializer.deserialize({"_t": "r2", "x": 1.5, "y": -2.0, "w": 3.25, "h": 4.5})).is_equal(
		Rect2(Vector2(1.5, -2.0), Vector2(3.25, 4.5))
	)
	assert_that(E2ESerializer.deserialize({"_t": "r2i", "x": 1, "y": -2, "w": 3, "h": 4})).is_equal(
		Rect2i(Vector2i(1, -2), Vector2i(3, 4))
	)
	assert_that(E2ESerializer.deserialize({"_t": "col", "r": 0.1, "g": 0.2, "b": 0.3, "a": 0.4})).is_equal(
		Color(0.1, 0.2, 0.3, 0.4)
	)
	assert_that(E2ESerializer.deserialize({
		"_t": "t2d",
		"x": {"_t": "v2", "x": 1.0, "y": 2.0},
		"y": {"_t": "v2", "x": 3.0, "y": 4.0},
		"o": {"_t": "v2", "x": 5.0, "y": 6.0},
	})).is_equal(Transform2D(Vector2(1, 2), Vector2(3, 4), Vector2(5, 6)))
	assert_that(E2ESerializer.deserialize({"_t": "np", "v": "root/player"})).is_equal(NodePath("root/player"))


func test_deserialize_recurses_through_untyped_dictionaries_and_preserves_unknown_tags() -> void:
	var unknown := {"_t": "_unknown", "_class": "Vector4", "_str": "(1.0, 2.0, 3.0, 4.0)"}
	var value := {"items": [{"_t": "v2", "x": 1.0, "y": 2.0}], "unknown": unknown}

	assert_that(E2ESerializer.deserialize(value)).is_equal({
		"items": [Vector2(1, 2)],
		"unknown": unknown,
	})
