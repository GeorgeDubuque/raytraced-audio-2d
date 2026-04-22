class_name RaytracedSound extends StaticBody2D

@onready var sound : AudioStreamPlayer2D = $Sound
@onready var collider : CollisionShape2D = $CollisionShape2D

var bus_name : String
var filter : AudioEffectLowPassFilter
var target_cutoff : float = 20000.0
var current_cutoff : float = 20000.0
var occlusion_percentage : float = 0.0
var color : Color = Color.from_hsv(randf(),randf_range(0.2, 0.6),randf_range(0.9, 1.0))

const SMOOTH_SPEED = 5.0

# every sound gets its own bus so we can apply a lowpass filter over it
func _ready() -> void:
	input_pickable = true
	_ensure_reverb_bus() # do we need this isnt this being created in the raytracedaudiolistener
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

func _process(delta: float) -> void:
	if absf(current_cutoff - target_cutoff) > 1.0:
		current_cutoff = lerp(current_cutoff, target_cutoff, SMOOTH_SPEED * delta)
		filter.cutoff_hz = current_cutoff

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		var idx = AudioServer.get_bus_index(bus_name)
		if idx != -1:
			AudioServer.remove_bus(idx)

func _input_event(_viewport: Viewport, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		sound.play()

func set_volume_ratio(ratio: float) -> void:
	occlusion_percentage = ratio
	target_cutoff = lerp(0.0, 20000.0, ratio)

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
