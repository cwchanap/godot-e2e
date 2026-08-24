extends GdUnitE2ETestSuite


func test_real_failure_captures_artifacts() -> void:
	var game := await launch_game()
	if is_failure():
		return
	fail("intentional characterization failure")
	return
