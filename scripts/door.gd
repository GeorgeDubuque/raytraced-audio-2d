extends StaticBody2D

@export var open_angle_deg: float = 90.0
@export var duration: float = 0.4

var _is_open: bool = false
var _tween: Tween


func _ready() -> void:
	input_pickable = true


func _input_event(_viewport: Viewport, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_toggle()


func _toggle() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	var target: float = deg_to_rad(open_angle_deg) if not _is_open else 0.0
	_tween.tween_property(self, "rotation", target, duration)
	_is_open = not _is_open
