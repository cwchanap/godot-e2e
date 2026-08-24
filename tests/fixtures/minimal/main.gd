extends Node2D


@onready var status: Label = $Status
@onready var click_status: Label = $ClickStatus
var action_count := 0


func _ready() -> void:
	$Button.pressed.connect(func(): click_status.text = "clicked")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		action_count += 1
		status.text = "accepted:%d" % action_count
