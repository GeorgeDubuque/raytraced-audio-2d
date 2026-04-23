extends Node2D

const PENETRATION_DIST: float = 0.5

const DEBUG_WALL_THICKNESS_LABEL_OFFSET: Vector2 = Vector2(10, -20)
const DEBUG_RAY_THICKNESS: float = 2.0

@export var max_bounces: int = 10
@export var num_rays: int = 16
@export var draw_debug_rays: bool = false
@export var draw_penetretive_rays: bool = false
@export var draw_portal_positions: bool = false
@export var max_reverb_distance: float = 2000.0
@export var max_ray_distance: float = 2000.0
@export var max_wall_thickness: float = 50.0
@export_range(0.0, 1.0) var wall_thickenss_occlusion_weight: float = 0.5


class SoundData:
	var sound: RaytracedSound
	var hit_count: int = 0
	var portal_locations: Array[Vector2]

	func _init(new_sound: RaytracedSound):
		sound = new_sound


class OcclusionRay:
	var entry_points: Array[Vector2]
	var exit_points: Array[Vector2]
	var walls_thickness: float = 0
	var sound: RaytracedSound


class AudioRay:
	var points: Array[Vector2]
	var color: Color
	var hit_sounds: Dictionary[int, bool]
	var reflected_to_player: bool = false
	var reflection_distance: float = 0.0
	var last_line_of_sight: Vector2
	var has_los: bool = false
	var escaped: bool = false


var audio_rays: Array[AudioRay]
var occlusion_rays: Array[OcclusionRay]
var prev_pos: Vector2
var sound_nodes: Array[RaytracedSound]
var reverb_effect: AudioEffectReverb
var sound_data: Dictionary[int, SoundData]

@onready var label_room_size: Label = $CanvasLayer/VBoxContainer/Label_RoomSize
@onready var label_inside_outside: Label = $CanvasLayer/VBoxContainer/Label_InsideOutside
@onready var label_reverb_distance: Label = $CanvasLayer/VBoxContainer/Label_ReverbDistance


func _ready() -> void:
	var existing_sound_nodes = get_tree().root.find_children("*", "RaytracedSound", true, false)
	for sound in existing_sound_nodes:
		sound_nodes.append(sound as RaytracedSound)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	_setup_reverb_bus()


func _setup_reverb_bus() -> void:
	if AudioServer.get_bus_index("Reverb") != -1:
		reverb_effect = AudioServer.get_bus_effect(AudioServer.get_bus_index("Reverb"), 0)
		return
	AudioServer.add_bus()
	var idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, "Reverb")
	AudioServer.set_bus_send(idx, "Master")
	reverb_effect = AudioEffectReverb.new()
	reverb_effect.wet = 0.0
	AudioServer.add_bus_effect(idx, reverb_effect)


func _on_node_added(node: Node) -> void:
	if node is RaytracedSound:
		sound_nodes.append(node)


func _on_node_removed(node: Node) -> void:
	sound_nodes.erase(node)


func get_contact_points_along_ray(start: Vector2, end: Vector2, exclude: Array) -> Array[Vector2]:
	var space_state = get_world_2d().direct_space_state
	var hit_target: bool = false
	var curr_pos: Vector2 = start
	var contact_points: Array[Vector2] = []
	# raycast from player to gather all entry points to walls
	while !hit_target:
		var query = PhysicsRayQueryParameters2D.create(curr_pos, end)
		query.exclude = exclude
		var result = space_state.intersect_ray(query)

		if result and result.collider:
			curr_pos = (result.position + (end - start).normalized() * 1)
			contact_points.append(curr_pos)
		else:
			hit_target = true

	return contact_points


func calculate_occlusion_for_sound(sound: RaytracedSound) -> void:
	var curr_sound_data: SoundData = sound_data.get(sound.get_instance_id(), SoundData.new(sound))
	sound_data[sound.get_instance_id()] = curr_sound_data

	var percentage_rays_hit_sound = float(curr_sound_data.hit_count) / num_rays

	var occlusion_ray: OcclusionRay = OcclusionRay.new()
	occlusion_ray.sound = curr_sound_data.sound
	var exclusions: Array = [get_parent(), curr_sound_data.sound.get_rid()]

	var entry_points = get_contact_points_along_ray(
		global_position, curr_sound_data.sound.global_position, exclusions
	)
	# raycast from sound to player to gather all exit points of walls
	var exit_points = get_contact_points_along_ray(
		curr_sound_data.sound.global_position, global_position, exclusions
	)
	occlusion_ray.entry_points = entry_points
	occlusion_ray.exit_points = exit_points

	if occlusion_ray.entry_points.size() != occlusion_ray.exit_points.size():
		print(
			(
				"Entry and exit points aren't the same length; truncating. %d, %d"
				% [occlusion_ray.entry_points.size(), occlusion_ray.exit_points.size()]
			)
		)

	var shortest_list_length = min(
		occlusion_ray.entry_points.size(), occlusion_ray.exit_points.size()
	)
	for i in range(shortest_list_length):
		occlusion_ray.walls_thickness += (
			(
				occlusion_ray.entry_points[i]
				- occlusion_ray.exit_points[occlusion_ray.exit_points.size() - 1 - i]
			)
			. length()
		)

	var wall_thickness_percentage = (
		1 - clampf(occlusion_ray.walls_thickness / max_wall_thickness, 0, 1)
	)

	occlusion_rays.append(occlusion_ray)

	curr_sound_data.sound.set_volume_ratio(
		(
			wall_thickness_percentage * wall_thickenss_occlusion_weight
			+ percentage_rays_hit_sound * (1 - wall_thickenss_occlusion_weight)
		)
	)

	# if curr_sound_data.portal_locations.size() > 0:
	# 	curr_sound_data.portal_location /= curr_sound_data.portal_locations.size()


func cast_ray(dir: Vector2) -> AudioRay:
	var new_ray: AudioRay = AudioRay.new()
	var space_state = get_world_2d().direct_space_state

	var current_pos = global_position
	var current_dir = dir

	new_ray.points.append(current_pos)

	for i in range(max_bounces):
		var target = current_pos + (current_dir * max_ray_distance)
		var query = PhysicsRayQueryParameters2D.create(current_pos, target)

		# exclude player on first segment only after bouncing allow it to be hit for echo detection
		if i == 0:
			query.exclude = [get_parent().get_rid()]

		var result = space_state.intersect_ray(query)

		if result:
			new_ray.points.append(result.position)

			# if we havnt already reflected to player count distance
			if !new_ray.reflected_to_player:
				new_ray.reflection_distance += current_pos.distance_to(result.position)

			# returned to player
			if result.collider == get_parent():
				new_ray.reflected_to_player = true
				# continue through collider collecting more info
				current_pos = result.position + (current_dir * PENETRATION_DIST)

			# hit a sound
			elif result.collider is RaytracedSound:
				var sound_id: int = result.collider.get_instance_id()
				if !new_ray.hit_sounds.has(sound_id):
					new_ray.hit_sounds[sound_id] = true

					var curr_sound_data: SoundData = sound_data.get(
						sound_id, SoundData.new(result.collider)
					)
					curr_sound_data.hit_count += 1

					if (
						new_ray.has_los
						and (
							new_ray.reflection_distance
							< curr_sound_data.sound.sound.max_distance * 2
						)
					):
						curr_sound_data.portal_locations.append(new_ray.last_line_of_sight)

					sound_data[sound_id] = curr_sound_data

				# continue through collider collecting more info
				current_pos = result.position + (current_dir * PENETRATION_DIST)
			else:
				var start_pos = result.position + (result.normal * 2)
				var los_query = PhysicsRayQueryParameters2D.create(start_pos, global_position)
				var los_result = space_state.intersect_ray(los_query)
				if los_result and los_result.collider == get_parent():
					new_ray.last_line_of_sight = result.position
					new_ray.has_los = true

				# bounce off collider
				current_dir = current_dir.bounce(result.normal).normalized()
				current_pos = result.position + (result.normal * PENETRATION_DIST)

		# escaped outside
		else:
			new_ray.reflection_distance += current_pos.distance_to(target)
			new_ray.points.append(target)
			new_ray.escaped = true
			return new_ray

	return new_ray


func _process(_delta: float) -> void:
	if prev_pos == global_position:
		return

	audio_rays.clear()
	sound_data.clear()
	occlusion_rays.clear()

	var space_state = get_world_2d().direct_space_state
	# gather ray data
	for i in range(num_rays):
		var angle = (TAU / num_rays) * i
		var dir = Vector2.RIGHT.rotated(angle)
		var new_ray = cast_ray(dir)
		new_ray.color = Color.RED
		audio_rays.append(new_ray)

	for sound_node: RaytracedSound in sound_nodes:
		calculate_occlusion_for_sound(sound_node)
		var curr_sound_data = sound_data[sound_node.get_instance_id()]
		# should portal
		var los_query = PhysicsRayQueryParameters2D.create(
			curr_sound_data.sound.global_position, global_position
		)
		los_query.exclude = [curr_sound_data.sound.collider]

		var result = space_state.intersect_ray(los_query)
		if result and result.collider != get_parent():
			if curr_sound_data.portal_locations.size() > 0:
				var avg_portal_loc: Vector2 = Vector2.ZERO
				for portal_loc in curr_sound_data.portal_locations:
					avg_portal_loc += portal_loc
				avg_portal_loc /= curr_sound_data.portal_locations.size()
				var portal_pos = (
					global_position + (avg_portal_loc - global_position).normalized() * 500
				)
				sound_node.portal_sound.global_position = portal_pos
				var portal_ratio = float(curr_sound_data.portal_locations.size()) / num_rays
				sound_node.portal_sound.volume_db = linear_to_db(portal_ratio)
			else:
				sound_node.portal_sound.position = Vector2.ZERO
				sound_node.portal_sound.volume_db = -100.0
		else:
			sound_node.portal_sound.position = Vector2.ZERO
			sound_node.portal_sound.volume_db = 0.0

	# compute reverb from rays that bounced back to the player
	var avg_reverb_distance = 0.0
	var echo_rays: Array[AudioRay] = audio_rays.filter(func(r): return r.reflected_to_player)
	if echo_rays.size() > 0:
		for ray: AudioRay in echo_rays:
			avg_reverb_distance += ray.reflection_distance
		avg_reverb_distance /= echo_rays.size()
		#reverb_effect.wet = 1.0
	else:
		reverb_effect.wet = 0.0

	reverb_effect.wet = clampf(float(echo_rays.size()) / num_rays, 0.0, 1.0)
	reverb_effect.room_size = (
		clampf(avg_reverb_distance / max_reverb_distance, 0.0, 1.0) * reverb_effect.wet
	)

	label_room_size.text = "Room Size: %f" % reverb_effect.room_size
	label_inside_outside.text = "Wet: %f" % reverb_effect.wet
	label_reverb_distance.text = "Reverb Distance: %f" % avg_reverb_distance

	queue_redraw()

	prev_pos = global_position


func _draw() -> void:
	if draw_debug_rays:
		for audio_ray in audio_rays:
			for i in range(audio_ray.points.size() - 1):
				var p1 = to_local(audio_ray.points[i])
				draw_circle(p1, 5, Color(0.0, 1, 0, 0.5))
				var p2 = to_local(audio_ray.points[i + 1])
				draw_circle(p2, 5, Color(0.0, 0, 1, 0.5))
				if audio_ray.reflected_to_player:
					draw_line(p1, p2, Color.BLUE, DEBUG_RAY_THICKNESS)
				elif audio_ray.hit_sounds.size() > 0:
					draw_line(p1, p2, Color.GREEN, DEBUG_RAY_THICKNESS)
				else:
					draw_line(p1, p2, audio_ray.color, DEBUG_RAY_THICKNESS)

	if draw_penetretive_rays:
		for occlusion_ray: OcclusionRay in occlusion_rays:
			var start_pos: Vector2 = to_local(global_position)
			var shortest_list_length = min(
				occlusion_ray.entry_points.size(), occlusion_ray.exit_points.size()
			)
			for i in range(shortest_list_length):
				var p1 = to_local(occlusion_ray.entry_points[i])
				var p2 = to_local(
					occlusion_ray.exit_points[occlusion_ray.exit_points.size() - 1 - i]
				)
				draw_circle(p1, 5, Color.GREEN)
				draw_circle(p2, 5, Color.RED)
				draw_line(start_pos, p1, Color.YELLOW_GREEN, DEBUG_RAY_THICKNESS)
				draw_dashed_line(p1, p2, Color.PALE_VIOLET_RED, DEBUG_RAY_THICKNESS)
				start_pos = p2

			if occlusion_ray.exit_points.size() > 0:
				draw_line(
					to_local(occlusion_ray.exit_points[0]),
					to_local(occlusion_ray.sound.global_position),
					Color.YELLOW_GREEN,
					1.0
				)

			var label_pos = to_local(
				occlusion_ray.sound.global_position + DEBUG_WALL_THICKNESS_LABEL_OFFSET
			)
			# var percentage_rays_hit_sound = float(sound_data.get(occlusion_ray.sound, 0)) / num_rays
			var percentage_rays_hit_sound = (
				float(sound_data[occlusion_ray.sound.get_instance_id()].hit_count) / num_rays
			)
			draw_string(
				ThemeDB.fallback_font,
				label_pos,
				"Wall thickeness: %.1f" % occlusion_ray.walls_thickness,
				HORIZONTAL_ALIGNMENT_CENTER,
				-1,
				14,
				Color.WHITE
			)
			draw_string(
				ThemeDB.fallback_font,
				label_pos + Vector2(0, -15),
				"Rays Percent: %.1f" % percentage_rays_hit_sound,
				HORIZONTAL_ALIGNMENT_CENTER,
				-1,
				14,
				Color.WHITE
			)
			draw_string(
				ThemeDB.fallback_font,
				label_pos + Vector2(0, -30),
				"Cutoff Hz: %.1f" % occlusion_ray.sound.target_cutoff,
				HORIZONTAL_ALIGNMENT_CENTER,
				-1,
				14,
				Color.WHITE
			)
			draw_string(
				ThemeDB.fallback_font,
				label_pos + Vector2(0, -45),
				"Occlusion Percentage: %.1f" % occlusion_ray.sound.occlusion_percentage,
				HORIZONTAL_ALIGNMENT_CENTER,
				-1,
				14,
				Color.WHITE
			)

	if draw_portal_positions:
		for curr_sound_data: SoundData in sound_data.values():
			if curr_sound_data.portal_locations.size() > 0:
				var avg: Vector2 = Vector2.ZERO
				for loc in curr_sound_data.portal_locations:
					avg += loc
				avg /= curr_sound_data.portal_locations.size()
				draw_circle(to_local(avg), 5.0, Color.PURPLE, true)
