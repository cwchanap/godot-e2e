extends Node2D


signal pinged(count: int)
signal ticked

@onready var status: Label = $Status
@onready var click_status: Label = $ClickStatus
var action_count := 0
var action_release_count := 0
var action_pressed := false
var pinging := false
var ping_count := 0


func _ready() -> void:
	$Button.pressed.connect(func(): click_status.text = "clicked")


## Emits `pinged` (one argument) and `ticked` (none) every frame while
## `pinging` is set, so a later wait_for_signal always has an emission to catch.
func _process(_delta: float) -> void:
	if not pinging:
		return
	ping_count += 1
	pinged.emit(ping_count)
	ticked.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		action_count += 1
		action_pressed = true
		status.text = "accepted:%d" % action_count
	elif event.is_action_released("ui_accept"):
		action_release_count += 1
		action_pressed = false


## Emits `line_count` lines of ~80 bytes to stdout. Used by the pipe-drain
## regression test to fill the OS pipe buffer without relying on the server's
## info-level logging (which triggers the log-capture feedback loop).
func emit_noise(line_count: int) -> int:
	for i in line_count:
		print("noise line %d: %s" % [i, "x".repeat(80)])
	return line_count
