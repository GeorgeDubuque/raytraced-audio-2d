@tool
class_name RaytracedSound extends StaticBody2D

const SMOOTH_SPEED = 5.0

var bus_name: String
var filter: AudioEffectLowPassFilter
var target_cutoff: float = 20000.0
var current_cutoff: float = 20000.0
var occlusion_percentage: float = 0.0
var color: Color = Color.from_hsv(randf(), randf_range(0.2, 0.6), randf_range(0.9, 1.0))

@onready var sound: AudioStreamPlayer2D = $Sound
@onready var portal_sound: AudioStreamPlayer2D = $PortalSound
@onready var collider: CollisionShape2D = $CollisionShape2D
@onready var sprite_sound: Polygon2D = $MainSoundSprite
@onready var sprite_portal_sound: Polygon2D = $PortalSound/PortalSoundSprite


func _draw() -> void:
	var sound_node := get_node_or_null("Sound") as AudioStreamPlayer2D
	if sound_node:
		var r := sound_node.max_distance
		draw_circle(Vector2.ZERO, r, Color(color.r, color.g, color.b, 0.08))
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 64, Color(color.r, color.g, color.b, 0.6), 2.0)
	if portal_sound:
		var pr := portal_sound.max_distance
		var pp := portal_sound.position
		draw_circle(pp, pr, Color(color.r, color.g, color.b, 0.05))
		draw_arc(pp, pr, 0.0, TAU, 64, Color(color.r, color.g, color.b, 0.4), 2.0)


# every sound gets its own bus so we can apply a lowpass filter over it
func _ready() -> void:
	queue_redraw()
	if Engine.is_editor_hint():
		return
	input_pickable = true
	_ensure_reverb_bus()  # do we need this isnt this being created in the raytracedaudiolistener
	bus_name = "Sound_" + str(get_instance_id())
	AudioServer.add_bus()
	var bus_idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(bus_idx, bus_name)
	# Route through Reverb bus so reverb is applied; Reverb sends to Master
	AudioServer.set_bus_send(bus_idx, "Reverb")
	filter = AudioEffectLowPassFilter.new()
	filter.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(bus_idx, filter)
	sound.bus = bus_name
	sprite_sound.color = color
	sprite_portal_sound.color = color
	portal_sound.stream = sound.stream
	portal_sound.max_distance = sound.max_distance
	portal_sound.play()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		queue_redraw()
		return
	if absf(current_cutoff - target_cutoff) > 1.0:
		current_cutoff = lerp(current_cutoff, target_cutoff, SMOOTH_SPEED * delta)
		filter.cutoff_hz = current_cutoff

	queue_redraw()


func _notification(what: int) -> void:
	if Engine.is_editor_hint():
		return
	if what == NOTIFICATION_PREDELETE:
		var idx = AudioServer.get_bus_index(bus_name)
		if idx != -1:
			AudioServer.remove_bus(idx)


func _input_event(_viewport: Viewport, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		sound.play()


func set_volume_ratio(ratio: float) -> void:
	occlusion_percentage = ratio
	target_cutoff = lerp(20000.0, 0.0, ratio)


static func _ensure_reverb_bus() -> void:
	if AudioServer.get_bus_index("Reverb") != -1:
		return
	AudioServer.add_bus()
	var idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, "Reverb")
	AudioServer.set_bus_send(idx, "Master")
	var reverb = AudioEffectReverb.new()
	reverb.wet = 0.0
	AudioServer.add_bus_effect(idx, reverb)
