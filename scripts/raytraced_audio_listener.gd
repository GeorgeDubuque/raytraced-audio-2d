extends Node2D

const PENETRATION_DIST: float = 0.5

const DEBUG_WALL_THICKNESS_LABEL_OFFSET: Vector2 = Vector2(10, -20)
const DEBUG_RAY_THICKNESS: float = 2.0

@export var max_bounces: int = 10
@export var num_rays: int = 16
@export var draw_debug_snapshot: bool = false
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
var thread: Thread

var _shape_cache: Array  # Array of Dicts; body refs + raw shape data, rebuilt on add/remove

@onready var label_room_size: Label = $CanvasLayer/VBoxContainer/Label_RoomSize
@onready var label_inside_outside: Label = $CanvasLayer/VBoxContainer/Label_InsideOutside
@onready var label_reverb_distance: Label = $CanvasLayer/VBoxContainer/Label_ReverbDistance


func _ready() -> void:
	thread = Thread.new()
	var existing_sound_nodes = get_tree().root.find_children("*", "RaytracedSound", true, false)
	for sound in existing_sound_nodes:
		sound_nodes.append(sound as RaytracedSound)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	_setup_reverb_bus()
	_cache_shape_data()


func _cache_shape_data() -> void:
	_shape_cache = []
	var bodies = get_tree().root.find_children("*", "CollisionObject2D", true, false)
	for body in bodies:
		if not (body is StaticBody2D or body is CharacterBody2D):
			continue
		var is_sound: bool = body is RaytracedSound
		var is_player: bool = body == get_parent()
		var body_rid: RID = body.get_rid()
		var count: int = PhysicsServer2D.body_get_shape_count(body_rid)
		for i in range(count):
			var shape_rid   = PhysicsServer2D.body_get_shape(body_rid, i)
			var shape_type  = PhysicsServer2D.shape_get_type(shape_rid)
			var shape_data  = PhysicsServer2D.shape_get_data(shape_rid)
			var local_xform: Transform2D = PhysicsServer2D.body_get_shape_transform(body_rid, i)
			var entry: Dictionary = {
				"body": body, "local_xform": local_xform,
				"is_sound": is_sound, "is_player": is_player,
				"sound_id": body.get_instance_id() if is_sound else -1,
			}
			match shape_type:
				PhysicsServer2D.SHAPE_CIRCLE:
					entry["is_circle"] = true
					entry["radius"] = float(shape_data)
				PhysicsServer2D.SHAPE_RECTANGLE:
					var he: Vector2 = shape_data
					entry["is_circle"] = false
					entry["local_verts"] = PackedVector2Array([
						Vector2(-he.x, -he.y), Vector2(he.x, -he.y),
						Vector2(he.x,  he.y),  Vector2(-he.x, he.y)])
				PhysicsServer2D.SHAPE_CONVEX_POLYGON:
					entry["is_circle"] = false
					entry["local_verts"] = shape_data as PackedVector2Array
				PhysicsServer2D.SHAPE_CONCAVE_POLYGON:
					entry["is_circle"] = false
					entry["local_verts"] = shape_data as PackedVector2Array
					entry["is_concave"] = true
				_:
					continue
			_shape_cache.append(entry)


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
		_cache_shape_data()


func _on_node_removed(node: Node) -> void:
	sound_nodes.erase(node)
	if node is RaytracedSound:
		_cache_shape_data()


func _build_frame_snapshot() -> Array:
	var snapshot: Array = []
	for cached in _shape_cache:
		var body: Node2D = cached["body"]
		if not is_instance_valid(body):
			continue
		var gxform: Transform2D = body.global_transform * cached["local_xform"]
		if cached.get("is_circle", false):
			snapshot.append({
				"is_circle": true, "center": gxform.origin, "radius": cached["radius"],
				"is_sound": cached["is_sound"], "is_player": cached["is_player"],
				"sound_id": cached["sound_id"],
			})
			continue
		var segs: Array = []
		var norms: Array = []
		if cached.get("is_concave", false):
			var verts: PackedVector2Array = cached["local_verts"]
			for i in range(0, verts.size(), 2):
				var a: Vector2 = gxform * verts[i]
				var b: Vector2 = gxform * verts[i + 1]
				segs.append([a, b])
				var n: Vector2 = (b - a).rotated(PI * 0.5).normalized()
				norms.append(n)  # concave shapes are already correctly wound
		else:
			var verts: PackedVector2Array = cached["local_verts"]
			var gv: Array[Vector2] = []
			for v in verts:
				gv.append(gxform * v)
			var centroid: Vector2 = Vector2.ZERO
			for v in gv: centroid += v
			centroid /= gv.size()
			for i in range(gv.size()):
				var a: Vector2 = gv[i]
				var b: Vector2 = gv[(i + 1) % gv.size()]
				segs.append([a, b])
				var mid: Vector2 = (a + b) * 0.5
				var n: Vector2 = (b - a).rotated(PI * 0.5).normalized()
				if n.dot(mid - centroid) < 0:
					n = -n
				norms.append(n)
		snapshot.append({
			"is_circle": false, "segments": segs, "normals": norms,
			"is_sound": cached["is_sound"], "is_player": cached["is_player"],
			"sound_id": cached["sound_id"],
		})
	return snapshot


func _build_sound_infos() -> Array:
	var infos: Array = []
	for s: RaytracedSound in sound_nodes:
		if is_instance_valid(s):
			infos.append({
				"instance_id": s.get_instance_id(),
				"position": s.global_position,
				"max_distance": s.sound.max_distance,
			})
	return infos


static func _ray_seg(origin: Vector2, dir: Vector2, a: Vector2, b: Vector2) -> Dictionary:
	var s: Vector2 = b - a
	var e: Vector2 = a - origin  # E = A - O (not O - A)
	var denom: float = dir.x * s.y - dir.y * s.x
	if absf(denom) < 1e-8:
		return {}
	# t = (E×S)/denom, u = (E×D)/denom
	var t: float = (e.x * s.y - e.y * s.x) / denom
	var u: float = (e.x * dir.y - e.y * dir.x) / denom
	if t < 1e-4 or t > 1.0 or u < 0.0 or u > 1.0:
		return {}
	return {"t": t, "pos": origin + dir * t}


static func _ray_circle(origin: Vector2, dir: Vector2, center: Vector2, radius: float) -> Dictionary:
	var oc: Vector2 = origin - center
	var a: float = dir.dot(dir)  # |dir|^2; dir is not assumed unit
	var b: float = 2.0 * oc.dot(dir)
	var c: float = oc.dot(oc) - radius * radius
	var disc: float = b * b - 4.0 * a * c
	if disc < 0.0:
		return {}
	var t: float = (-b - sqrt(disc)) / (2.0 * a)
	if t < 1e-4:
		t = (-b + sqrt(disc)) / (2.0 * a)
	if t < 1e-4 or t > 1.0:
		return {}
	var pos: Vector2 = origin + dir * t
	return {"t": t, "pos": pos, "normal": (pos - center).normalized()}


static func _find_hit(origin: Vector2, dir: Vector2, snapshot: Array, skip_player: bool) -> Dictionary:
	var best_t: float = INF
	var best: Dictionary = {}
	var best_shape: Dictionary = {}
	for shape in snapshot:
		if skip_player and shape.get("is_player", false):
			continue
		if shape.get("is_circle", false):
			var r: Dictionary = _ray_circle(origin, dir, shape["center"], shape["radius"])
			if not r.is_empty() and r["t"] < best_t:
				best_t = r["t"]
				best = r
				best["normal"] = r["normal"]
				best_shape = shape
		else:
			var segs: Array = shape["segments"]
			var norms: Array = shape["normals"]
			for i in range(segs.size()):
				var seg = segs[i]
				var r: Dictionary = _ray_seg(origin, dir, seg[0], seg[1])
				if not r.is_empty() and r["t"] < best_t:
					var n: Vector2 = norms[i]
					if n.dot(-dir) < 0.0:
						continue  # skip back-face hits; matches Godot physics behaviour
					best_t = r["t"]
					best = r
					best["normal"] = n
					best_shape = shape
	if best.is_empty():
		return {}
	best["shape"] = best_shape
	return best


static func _sound_max_dist(sound_infos: Array, sid: int) -> float:
	for info in sound_infos:
		if info["instance_id"] == sid:
			return info["max_distance"]
	return INF


func _cast_ray_snapshot(
	dir: Vector2, snapshot: Array, listener_pos: Vector2,
	sound_infos: Array, state: Dictionary, n_bounces: int, ray_dist: float
) -> Dictionary:
	var ray: Dictionary = {
		"points": [listener_pos], "hit_sounds": {}, "reflected_to_player": false,
		"reflection_distance": 0.0, "last_line_of_sight": Vector2.ZERO,
		"has_los": false, "escaped": false,
	}
	var pos: Vector2 = listener_pos
	var d: Vector2 = dir
	for i in range(n_bounces):
		var result: Dictionary = _find_hit(pos, d * ray_dist, snapshot, i == 0)
		if result.is_empty():
			ray["reflection_distance"] += pos.distance_to(pos + d * ray_dist)
			ray["points"].append(pos + d * ray_dist)
			ray["escaped"] = true
			return ray
		if not ray["reflected_to_player"]:
			ray["reflection_distance"] += pos.distance_to(result["pos"])
		ray["points"].append(result["pos"])
		var shape: Dictionary = result["shape"]
		if shape.get("is_player", false):
			ray["reflected_to_player"] = true
			pos = result["pos"] + d * PENETRATION_DIST
		elif shape.get("is_sound", false):
			var sid: int = shape["sound_id"]
			if not ray["hit_sounds"].has(sid):
				ray["hit_sounds"][sid] = true
				if not state.has(sid):
					state[sid] = {"hit_count": 0, "portal_locations": []}
				state[sid]["hit_count"] += 1
				var max_dist: float = _sound_max_dist(sound_infos, sid)
				if ray["has_los"] and ray["reflection_distance"] < max_dist * 2.0:
					state[sid]["portal_locations"].append(ray["last_line_of_sight"])
			pos = result["pos"] + d * PENETRATION_DIST
		else:
			var normal: Vector2 = result["normal"]
			var los_origin: Vector2 = result["pos"] + normal * 2.0
			var los_dir: Vector2 = listener_pos - los_origin
			var los_hit: Dictionary = _find_hit(los_origin, los_dir, snapshot, false)
			if not los_hit.is_empty() and los_hit["shape"].get("is_player", false):
				ray["last_line_of_sight"] = result["pos"]
				ray["has_los"] = true
			d = d.bounce(normal).normalized()
			pos = result["pos"] + normal * PENETRATION_DIST
	return ray


func _get_contact_points_snapshot(
	from: Vector2, to: Vector2, snapshot: Array, exclude_sound_id: int
) -> Array[Vector2]:
	var pts: Array[Vector2] = []
	var curr: Vector2 = from
	var dir: Vector2 = to - from
	var step: Vector2 = dir.normalized()
	var i: int = 0
	while i < 100:
		i += 1
		var r: Dictionary = _find_hit(curr, dir, snapshot, false)
		if r.is_empty():
			break
		if r["shape"].get("is_player", false) or r["shape"].get("sound_id", -1) == exclude_sound_id:
			curr = r["pos"] + step
			dir = to - curr
			continue
		curr = r["pos"] + step
		dir = to - curr
		pts.append(curr)
	return pts


func _calculate_occlusion_snapshot(
	sound_info: Dictionary, listener_pos: Vector2, this_snapshot: Array,
	state: Dictionary, n_rays: int
) -> Dictionary:
	var sid: int = sound_info["instance_id"]
	var s_pos: Vector2 = sound_info["position"]
	var entry: Array[Vector2] = _get_contact_points_snapshot(listener_pos, s_pos, this_snapshot, sid)
	var exit_: Array[Vector2] = _get_contact_points_snapshot(s_pos, listener_pos, this_snapshot, sid)
	var n: int = min(entry.size(), exit_.size())
	var thickness: float = 0.0
	for i in range(n):
		thickness += (entry[i] - exit_[exit_.size() - 1 - i]).length()
	var los_hit: Dictionary = _find_hit(s_pos, listener_pos - s_pos, this_snapshot, false)
	var blocked: bool = not los_hit.is_empty() and not los_hit["shape"].get("is_player", false)
	var sd: Dictionary = state.get(sid, {})
	return {
		"sound_id": sid, "hit_count": sd.get("hit_count", 0),
		"thickness": thickness, "entry": entry, "exit": exit_,
		"portal_locs": sd.get("portal_locations", []),
		"blocked": blocked, "num_rays": n_rays,
	}


func _do_background_work(args: Dictionary) -> Dictionary:
	var snapshot: Array = args["snapshot"]
	var listener_pos: Vector2 = args["listener_pos"]
	var sound_infos: Array = args["sound_infos"]
	var n_rays: int = args["num_rays"]
	var n_bounces: int = args["max_bounces"]
	var ray_dist: float = args["max_ray_distance"]
	var state: Dictionary = {}

	var ray_results: Array = []
	for i in range(n_rays):
		ray_results.append(_cast_ray_snapshot(
			Vector2.RIGHT.rotated((TAU / n_rays) * i),
			snapshot, listener_pos, sound_infos, state, n_bounces, ray_dist))

	var occ_results: Array = []
	for info in sound_infos:
		occ_results.append(_calculate_occlusion_snapshot(
			info, listener_pos, snapshot, state, n_rays))

	var echo_count: int = 0
	var echo_dist: float = 0.0
	for r in ray_results:
		if r["reflected_to_player"]:
			echo_count += 1
			echo_dist += r["reflection_distance"]

	return {
		"rays": ray_results, "occlusion": occ_results,
		"echo_count": echo_count, "echo_dist": echo_dist, "num_rays": n_rays,
	}


func _find_sound_by_id(id: int) -> RaytracedSound:
	for s: RaytracedSound in sound_nodes:
		if is_instance_valid(s) and s.get_instance_id() == id:
			return s
	return null


func _apply_results(results: Dictionary) -> void:
	audio_rays.clear()
	for rd in results["rays"]:
		var ar: AudioRay = AudioRay.new()
		ar.points.assign(rd["points"])
		for k in rd["hit_sounds"]:
			ar.hit_sounds[k] = rd["hit_sounds"][k]
		ar.reflected_to_player = rd["reflected_to_player"]
		ar.reflection_distance = rd["reflection_distance"]
		ar.last_line_of_sight = rd["last_line_of_sight"]
		ar.has_los = rd["has_los"]
		ar.escaped = rd["escaped"]
		ar.color = Color.RED
		audio_rays.append(ar)

	occlusion_rays.clear()
	sound_data.clear()
	for occ in results["occlusion"]:
		var sound_node: RaytracedSound = _find_sound_by_id(occ["sound_id"])
		if not sound_node:
			continue

		var or_: OcclusionRay = OcclusionRay.new()
		or_.sound = sound_node
		or_.entry_points.assign(occ["entry"])
		or_.exit_points.assign(occ["exit"])
		or_.walls_thickness = occ["thickness"]
		occlusion_rays.append(or_)

		var sd: SoundData = SoundData.new(sound_node)
		sd.hit_count = occ["hit_count"]
		sd.portal_locations.assign(occ["portal_locs"])
		sound_data[occ["sound_id"]] = sd

		var thick_pct: float = 1.0 - clampf(occ["thickness"] / max_wall_thickness, 0.0, 1.0)
		var ray_pct: float = float(occ["hit_count"]) / float(occ["num_rays"])
		sound_node.set_volume_ratio(
			thick_pct * wall_thickenss_occlusion_weight
			+ ray_pct * (1.0 - wall_thickenss_occlusion_weight)
		)

		if occ["blocked"]:
			var portal_locs: Array = occ["portal_locs"]
			if portal_locs.size() > 0:
				var avg: Vector2 = Vector2.ZERO
				for loc: Vector2 in portal_locs:
					avg += loc
				avg /= portal_locs.size()
				sound_node.portal_sound.global_position = (
					global_position + (avg - global_position).normalized() * 500.0
				)
				sound_node.portal_sound.volume_db = linear_to_db(
					float(portal_locs.size()) / float(occ["num_rays"])
				)
			else:
				sound_node.portal_sound.position = Vector2.ZERO
				sound_node.portal_sound.volume_db = -100.0
		else:
			sound_node.portal_sound.position = Vector2.ZERO
			sound_node.portal_sound.volume_db = 0.0

	var n: int = results["num_rays"]
	var ec: int = results["echo_count"]
	reverb_effect.wet = clampf(float(ec) / n, 0.0, 1.0)
	var avg_dist: float = results["echo_dist"] / float(max(ec, 1))
	reverb_effect.room_size = clampf(avg_dist / max_reverb_distance, 0.0, 1.0) * reverb_effect.wet
	label_room_size.text = "Room Size: %f" % reverb_effect.room_size
	label_inside_outside.text = "Wet: %f" % reverb_effect.wet
	label_reverb_distance.text = "Reverb Distance: %f" % avg_dist
	queue_redraw()


var snapshot
func _physics_process(_delta: float) -> void:

	snapshot = _build_frame_snapshot()
	# queue_redraw()
	# return

	if thread.is_started() and not thread.is_alive():
		_apply_results(thread.wait_to_finish())

	if not thread.is_started() and global_position != prev_pos:
		prev_pos = global_position
		thread.start(_do_background_work.bind({
			"snapshot":     _build_frame_snapshot(),
			"listener_pos": global_position,
			"sound_infos":  _build_sound_infos(),
			"num_rays":     num_rays,
			"max_bounces":  max_bounces,
			"max_ray_distance": max_ray_distance,
			"max_reverb_distance": max_reverb_distance,
			"max_wall_thickness": max_wall_thickness,
			"wall_thickness_occlusion_weight": wall_thickenss_occlusion_weight,
		}))


func _draw() -> void:
	if draw_debug_snapshot:
		for shape_data in snapshot:
			if shape_data["is_circle"]:
				draw_circle(to_local(shape_data["center"]), shape_data["radius"], Color.DARK_RED, false, 5)
			else:
				for segment in shape_data["segments"]:
					draw_line(to_local(segment[0]), to_local(segment[1]), Color.GREEN, 5)	
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
