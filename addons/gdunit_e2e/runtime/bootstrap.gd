extends Node

const BootstrapRunner = preload("bootstrap_runner.gd")


func _ready() -> void:
	var runner = BootstrapRunner.new()
	runner.name = "GdUnitE2EBootstrapRunner"
	# The SceneTree root is still inserting this bootstrap scene while _ready()
	# runs, so root-level startup infrastructure must be attached deferred.
	get_tree().root.add_child.call_deferred(runner)
