extends Node2D

@export var speed : float = 20
@export var zoom_speed : float = 0.1
@export var zoom_min : float = 0.1
@export var zoom_max : float = 3.0
@onready var cb2d : CharacterBody2D = $CharacterBody2D
@onready var camera : Camera2D = $CharacterBody2D/Camera2D

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.zoom = clamp(camera.zoom + Vector2.ONE * zoom_speed, Vector2.ONE * zoom_min, Vector2.ONE * zoom_max)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.zoom = clamp(camera.zoom - Vector2.ONE * zoom_speed, Vector2.ONE * zoom_min, Vector2.ONE * zoom_max)

func _physics_process(delta: float) -> void:
	var input_vector = Input.get_vector("move_left","move_right","move_up","move_down")
	if input_vector:
		cb2d.velocity = input_vector * speed
	else:
		cb2d.velocity = cb2d.velocity.move_toward(Vector2.ZERO, speed)
	
	cb2d.move_and_slide();
