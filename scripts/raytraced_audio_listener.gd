extends Node2D

const PENETRATION_DIST: float = 0.5

const DEBUG_WALL_THICKNESS_LABEL_OFFSET: Vector2 = Vector2(10, -20)
const DEBUG_RAY_THICKNESS: float = 2.0

@export var max_bounces: int = 10
@export var max_los_bounces: int = 3
@export var num_rays: int = 16
@export var draw_debug_snapshot: bool = false
@export var draw_debug_rays: bool = false
@export var draw_penetretive_rays: bool = false
@export var draw_portal_positions: bool = false
@export var max_reverb_distance: float = 2000.0
@export var max_ray_distance: float = 2000.0
@export var max_wall_thickness: float = 50.0
@export var occlusion_curve: Curve
@export_range(0.0, 1.0) var wall_thickness_occlusion_weight: float = 0.5


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


class AudioCollision:
	var body_id: RID
	var local_xform: Transform2D
	var is_player: bool
	var is_sound: bool
	var instance_id: int
	var is_circle: bool = false
	var radius: float = 0.0
	var local_verts: PackedVector2Array = []
	var is_concave: bool = false

	func _init(
		in_body_id: RID,
		in_xform: Transform2D,
		in_is_player: bool,
		in_is_sound: bool,
		in_instance_id: int
	):
		body_id = in_body_id
		local_xform = in_xform
		is_player = in_is_player
		is_sound = in_is_sound
		instance_id = in_instance_id


class SnapshotShape:
	var is_circle: bool = false
	var is_player: bool = false
	var is_sound: bool = false
	var sound_id: int = -1
	var center: Vector2
	var radius: float = 0.0
	var seg_starts: PackedVector2Array
	var seg_ends: PackedVector2Array
	var normals: PackedVector2Array
	var aabb: Rect2


class RayHit:
	var t: float = 0.0
	var pos: Vector2
	var normal: Vector2
	var shape: SnapshotShape


class SoundInfo:
	var instance_id: int = 0
	var position: Vector2
	var max_distance: float = 0.0


class RayState:
	var hit_count: int = 0
	var portal_locations: Array[Vector2]


class OcclusionResult:
	var sound_id: int = 0
	var hit_count: int = 0
	var thickness: float = 0.0
	var entry: Array[Vector2]
	var exit_: Array[Vector2]
	var portal_locs: Array[Vector2]
	var blocked: bool = false
	var num_rays: int = 0

	func _init() -> void:
		entry = []
		exit_ = []
		portal_locs = []


class WorkArgs:
	var snapshot: Array[SnapshotShape]
	var listener_pos: Vector2
	var sound_infos: Array[SoundInfo]
	var num_rays: int = 0
	var max_bounces: int = 0
	var max_los_bounces: int = 0
	var max_ray_distance: float = 0.0


class BackgroundResult:
	var rays: Array[AudioRay]
	var occlusion: Array[OcclusionResult]
	var echo_count: int = 0
	var echo_dist: float = 0.0
	var num_rays: int = 0

	func _init() -> void:
		rays = []
		occlusion = []


var audio_rays: Array[AudioRay]
var occlusion_rays: Array[OcclusionRay]
var prev_pos: Vector2
var sound_nodes: Array[RaytracedSound]
var reverb_effect: AudioEffectReverb
var sound_data: Dictionary[int, SoundData]
var thread: Thread

var _shape_cache: Array[AudioCollision]

@onready var label_room_size: Label = $CanvasLayer/VBoxContainer/Label_RoomSize
@onready var label_inside_outside: Label = $CanvasLayer/VBoxContainer/Label_InsideOutside
@onready var label_reverb_distance: Label = $CanvasLayer/VBoxContainer/Label_ReverbDistance
@onready var label_thread_time: Label = $CanvasLayer/VBoxContainer/Label_ThreadTime


func _ready() -> void:
	thread = Thread.new()
	var existing_sound_nodes = get_tree().root.find_children("*", "RaytracedSound", true, false)
	for sound in existing_sound_nodes:
		sound_nodes.append(sound as RaytracedSound)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	_setup_reverb_bus()
	_shape_cache = _cache_shape_data()


func _build_body_shapes(body: Node) -> Array[AudioCollision]:
	var shapes: Array[AudioCollision] = []
	if not (body is StaticBody2D or body is CharacterBody2D):
		return shapes
	var is_sound: bool = body is RaytracedSound
	var is_player: bool = body == get_parent()
	var body_rid: RID = body.get_rid()
	var count: int = PhysicsServer2D.body_get_shape_count(body_rid)
	for i in range(count):
		var shape_rid = PhysicsServer2D.body_get_shape(body_rid, i)
		var shape_type = PhysicsServer2D.shape_get_type(shape_rid)
		var shape_data = PhysicsServer2D.shape_get_data(shape_rid)
		var local_xform: Transform2D = PhysicsServer2D.body_get_shape_transform(body_rid, i)
		var entry := AudioCollision.new(
			body_rid, local_xform, is_player, is_sound, body.get_instance_id() if is_sound else -1
		)
		match shape_type:
			PhysicsServer2D.SHAPE_CIRCLE:
				entry.is_circle = true
				entry.radius = float(shape_data)
			PhysicsServer2D.SHAPE_RECTANGLE:
				var he: Vector2 = shape_data
				entry.local_verts = PackedVector2Array(
					[
						Vector2(-he.x, -he.y),
						Vector2(he.x, -he.y),
						Vector2(he.x, he.y),
						Vector2(-he.x, he.y)
					]
				)
			PhysicsServer2D.SHAPE_CONVEX_POLYGON:
				entry.local_verts = shape_data as PackedVector2Array
			PhysicsServer2D.SHAPE_CONCAVE_POLYGON:
				entry.local_verts = shape_data as PackedVector2Array
				entry.is_concave = true
			_:
				continue
		shapes.append(entry)
	return shapes


func _cache_shape_data() -> Array[AudioCollision]:
	var shape_cache: Array[AudioCollision] = []
	for body in get_tree().root.find_children("*", "CollisionObject2D", true, false):
		shape_cache.append_array(_build_body_shapes(body))

	return shape_cache


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
		_shape_cache.append_array(_build_body_shapes(node))


func _on_node_removed(node: Node) -> void:
	sound_nodes.erase(node)
	if node is RaytracedSound:
		var body_rid: RID = (node as CollisionObject2D).get_rid()
		_shape_cache = _shape_cache.filter(
			func(ac: AudioCollision) -> bool: return ac.body_id != body_rid
		)


func _build_frame_snapshot() -> Array[SnapshotShape]:
	var snap: Array[SnapshotShape] = []
	for cached: AudioCollision in _shape_cache:
		if not cached.body_id.is_valid():
			continue
		var global_body_xform := (
			PhysicsServer2D.body_get_state(cached.body_id, PhysicsServer2D.BODY_STATE_TRANSFORM)
			as Transform2D
		)
		var gxform: Transform2D = global_body_xform * cached.local_xform
		var shape := SnapshotShape.new()
		shape.is_circle = cached.is_circle
		shape.is_sound = cached.is_sound
		shape.is_player = cached.is_player
		shape.sound_id = cached.instance_id
		if cached.is_circle:
			shape.center = gxform.origin
			shape.radius = cached.radius
			shape.aabb = Rect2(
				shape.center - Vector2(shape.radius, shape.radius),
				Vector2(shape.radius * 2.0, shape.radius * 2.0)
			)
		elif cached.is_concave:
			var verts: PackedVector2Array = cached.local_verts
			var starts := PackedVector2Array()
			var ends := PackedVector2Array()
			var norms := PackedVector2Array()
			for i in range(0, verts.size(), 2):
				var a: Vector2 = gxform * verts[i]
				var b: Vector2 = gxform * verts[i + 1]
				starts.append(a)
				ends.append(b)
				norms.append((b - a).rotated(PI * 0.5).normalized())  # concave shapes are already correctly wound
			shape.seg_starts = starts
			shape.seg_ends = ends
			shape.normals = norms
			shape.aabb = _aabb_of_segments(starts, ends)
		else:
			var verts: PackedVector2Array = cached.local_verts
			var gv: Array[Vector2] = []
			for v in verts:
				gv.append(gxform * v)
			var centroid: Vector2 = Vector2.ZERO
			for v in gv:
				centroid += v
			centroid /= gv.size()
			var starts := PackedVector2Array()
			var ends := PackedVector2Array()
			var norms := PackedVector2Array()
			for i in range(gv.size()):
				var a: Vector2 = gv[i]
				var b: Vector2 = gv[(i + 1) % gv.size()]
				starts.append(a)
				ends.append(b)
				var mid: Vector2 = (a + b) * 0.5
				var n: Vector2 = (b - a).rotated(PI * 0.5).normalized()
				if n.dot(mid - centroid) < 0:
					n = -n
				norms.append(n)
			shape.seg_starts = starts
			shape.seg_ends = ends
			shape.normals = norms
			shape.aabb = _aabb_of_segments(starts, ends)
		snap.append(shape)
	return snap


func _build_sound_infos() -> Array[SoundInfo]:
	var infos: Array[SoundInfo] = []
	for s: RaytracedSound in sound_nodes:
		if is_instance_valid(s):
			var info := SoundInfo.new()
			info.instance_id = s.get_instance_id()
			info.position = s.global_position
			info.max_distance = s.sound.max_distance
			infos.append(info)
	return infos


static func _aabb_of_segments(starts: PackedVector2Array, ends: PackedVector2Array) -> Rect2:
	var min_x: float = INF
	var min_y: float = INF
	var max_x: float = -INF
	var max_y: float = -INF
	for p in starts:
		min_x = minf(min_x, p.x)
		min_y = minf(min_y, p.y)
		max_x = maxf(max_x, p.x)
		max_y = maxf(max_y, p.y)
	for p in ends:
		min_x = minf(min_x, p.x)
		min_y = minf(min_y, p.y)
		max_x = maxf(max_x, p.x)
		max_y = maxf(max_y, p.y)
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)


static func _ray_hits_aabb(origin: Vector2, dir: Vector2, aabb: Rect2) -> bool:
	var t_min: float = -INF
	var t_max: float = INF
	if absf(dir.x) < 1e-8:
		if origin.x < aabb.position.x or origin.x > aabb.end.x:
			return false
	else:
		var t1: float = (aabb.position.x - origin.x) / dir.x
		var t2: float = (aabb.end.x - origin.x) / dir.x
		t_min = maxf(t_min, minf(t1, t2))
		t_max = minf(t_max, maxf(t1, t2))
	if absf(dir.y) < 1e-8:
		if origin.y < aabb.position.y or origin.y > aabb.end.y:
			return false
	else:
		var t1: float = (aabb.position.y - origin.y) / dir.y
		var t2: float = (aabb.end.y - origin.y) / dir.y
		t_min = maxf(t_min, minf(t1, t2))
		t_max = minf(t_max, maxf(t1, t2))
	return t_max >= t_min and t_max > 1e-4 and t_min <= 1.0


static func _ray_seg(origin: Vector2, dir: Vector2, a: Vector2, b: Vector2) -> RayHit:
	var s: Vector2 = b - a
	var e: Vector2 = a - origin  # E = A - O (not O - A)
	var denom: float = dir.x * s.y - dir.y * s.x
	if absf(denom) < 1e-8:
		return null
	# t = (E×S)/denom, u = (E×D)/denom
	var t: float = (e.x * s.y - e.y * s.x) / denom
	var u: float = (e.x * dir.y - e.y * dir.x) / denom
	if t < 1e-4 or t > 1.0 or u < 0.0 or u > 1.0:
		return null
	var hit := RayHit.new()
	hit.t = t
	hit.pos = origin + dir * t
	return hit


static func _ray_circle(origin: Vector2, dir: Vector2, center: Vector2, radius: float) -> RayHit:
	var oc: Vector2 = origin - center
	var a: float = dir.dot(dir)  # |dir|^2; dir is not assumed unit
	var b: float = 2.0 * oc.dot(dir)
	var c: float = oc.dot(oc) - radius * radius
	var disc: float = b * b - 4.0 * a * c
	if disc < 0.0:
		return null
	var t: float = (-b - sqrt(disc)) / (2.0 * a)
	if t < 1e-4:
		t = (-b + sqrt(disc)) / (2.0 * a)
	if t < 1e-4 or t > 1.0:
		return null
	var pos: Vector2 = origin + dir * t
	var hit := RayHit.new()
	hit.t = t
	hit.pos = pos
	hit.normal = (pos - center).normalized()
	return hit


static func _find_hit(origin: Vector2, dir: Vector2, snapshot: Array, skip_player: bool) -> RayHit:
	var best_t: float = INF
	var best: RayHit = null
	for shape: SnapshotShape in snapshot:
		if skip_player and shape.is_player:
			continue
		if not _ray_hits_aabb(origin, dir, shape.aabb):
			continue
		if shape.is_circle:
			var r: RayHit = _ray_circle(origin, dir, shape.center, shape.radius)
			if r != null and r.t < best_t:
				best_t = r.t
				r.shape = shape
				best = r
		else:
			for i in range(shape.seg_starts.size()):
				var r: RayHit = _ray_seg(origin, dir, shape.seg_starts[i], shape.seg_ends[i])
				if r != null and r.t < best_t:
					var n: Vector2 = shape.normals[i]
					if n.dot(-dir) < 0.0:
						continue  # skip back-face hits; matches Godot physics behaviour
					best_t = r.t
					r.normal = n
					r.shape = shape
					best = r
	return best


static func _sound_max_dist(sound_infos: Array, sid: int) -> float:
	for info: SoundInfo in sound_infos:
		if info.instance_id == sid:
			return info.max_distance
	return INF


func _cast_ray_snapshot(
	dir: Vector2,
	snapshot: Array,
	listener_pos: Vector2,
	sound_infos: Array,
	state: Dictionary,
	n_bounces: int,
	max_los: int,
	ray_dist: float
) -> AudioRay:
	var ray := AudioRay.new()
	ray.points.append(listener_pos)
	var pos: Vector2 = listener_pos
	var d: Vector2 = dir
	for i in range(n_bounces):
		var result: RayHit = _find_hit(pos, d * ray_dist, snapshot, i == 0)
		if result == null:
			ray.reflection_distance += pos.distance_to(pos + d * ray_dist)
			ray.points.append(pos + d * ray_dist)
			ray.escaped = true
			return ray
		if not ray.reflected_to_player:
			ray.reflection_distance += pos.distance_to(result.pos)
		ray.points.append(result.pos)
		var shape: SnapshotShape = result.shape
		if shape.is_player:
			ray.reflected_to_player = true
			pos = result.pos + d * PENETRATION_DIST
		elif shape.is_sound:
			var sid: int = shape.sound_id
			if not ray.hit_sounds.has(sid):
				ray.hit_sounds[sid] = true
				if not state.has(sid):
					state[sid] = RayState.new()
				var rs: RayState = state[sid]
				rs.hit_count += 1
				var max_dist: float = _sound_max_dist(sound_infos, sid)
				if ray.has_los and ray.reflection_distance < max_dist * 2.0:
					rs.portal_locations.append(ray.last_line_of_sight)
			pos = result.pos + d * PENETRATION_DIST
		else:
			var normal: Vector2 = result.normal
			if i < max_los:
				var los_origin: Vector2 = result.pos + normal * 2.0
				var los_hit: RayHit = _find_hit(los_origin, listener_pos - los_origin, snapshot, false)
				if los_hit != null and los_hit.shape.is_player:
					ray.last_line_of_sight = result.pos
					ray.has_los = true
			d = d.bounce(normal).normalized()
			pos = result.pos + normal * PENETRATION_DIST
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
		var r: RayHit = _find_hit(curr, dir, snapshot, false)
		if r == null:
			break
		if r.shape.is_player or r.shape.sound_id == exclude_sound_id:
			curr = r.pos + step
			dir = to - curr
			continue
		curr = r.pos + step
		dir = to - curr
		pts.append(curr)
	return pts


func _calculate_occlusion_snapshot(
	sound_info: SoundInfo,
	listener_pos: Vector2,
	this_snapshot: Array,
	state: Dictionary,
	n_rays: int
) -> OcclusionResult:
	var sid: int = sound_info.instance_id
	var s_pos: Vector2 = sound_info.position
	var entry: Array[Vector2] = _get_contact_points_snapshot(
		listener_pos, s_pos, this_snapshot, sid
	)
	var exit_: Array[Vector2] = _get_contact_points_snapshot(
		s_pos, listener_pos, this_snapshot, sid
	)
	var n: int = min(entry.size(), exit_.size())
	var thickness: float = 0.0
	for i in range(n):
		thickness += (entry[i] - exit_[exit_.size() - 1 - i]).length()
	var los_hit: RayHit = _find_hit(s_pos, listener_pos - s_pos, this_snapshot, false)
	var blocked: bool = los_hit != null and not los_hit.shape.is_player
	var rs: RayState = state.get(sid, null)
	var result := OcclusionResult.new()
	result.sound_id = sid
	result.hit_count = rs.hit_count if rs != null else 0
	result.thickness = thickness
	result.entry = entry
	result.exit_ = exit_
	if rs != null:
		result.portal_locs = rs.portal_locations
	result.blocked = blocked
	result.num_rays = n_rays
	return result


func _do_background_work(args: WorkArgs) -> BackgroundResult:
	var snapshot: Array = args.snapshot
	var listener_pos: Vector2 = args.listener_pos
	var sound_infos: Array = args.sound_infos
	var n_rays: int = args.num_rays
	var n_bounces: int = args.max_bounces
	var max_los: int = args.max_los_bounces
	var ray_dist: float = args.max_ray_distance
	var state: Dictionary = {}

	var result := BackgroundResult.new()
	result.num_rays = n_rays

	for i in range(n_rays):
		result.rays.append(
			_cast_ray_snapshot(
				Vector2.RIGHT.rotated((TAU / n_rays) * i),
				snapshot,
				listener_pos,
				sound_infos,
				state,
				n_bounces,
				max_los,
				ray_dist
			)
		)

	for info: SoundInfo in sound_infos:
		result.occlusion.append(
			_calculate_occlusion_snapshot(info, listener_pos, snapshot, state, n_rays)
		)

	for r: AudioRay in result.rays:
		if r.reflected_to_player:
			result.echo_count += 1
			result.echo_dist += r.reflection_distance

	return result


func _find_sound_by_id(id: int) -> RaytracedSound:
	for s: RaytracedSound in sound_nodes:
		if is_instance_valid(s) and s.get_instance_id() == id:
			return s
	return null


func _apply_results(results: BackgroundResult) -> void:
	audio_rays.clear()
	for ar: AudioRay in results.rays:
		ar.color = Color.RED
		audio_rays.append(ar)

	occlusion_rays.clear()
	sound_data.clear()
	for occ: OcclusionResult in results.occlusion:
		var sound_node: RaytracedSound = _find_sound_by_id(occ.sound_id)
		if not sound_node:
			continue

		var or_ := OcclusionRay.new()
		or_.sound = sound_node
		or_.entry_points.assign(occ.entry)
		or_.exit_points.assign(occ.exit_)
		or_.walls_thickness = occ.thickness
		occlusion_rays.append(or_)

		var sd := SoundData.new(sound_node)
		sd.hit_count = occ.hit_count
		sd.portal_locations.assign(occ.portal_locs)
		sound_data[occ.sound_id] = sd

		if occ.blocked:
			var thick_pct: float = clampf(occ.thickness / max_wall_thickness, 0.0, 1.0)
			var ray_pct: float = float(occ.hit_count) / float(occ.num_rays)
			var occlusion_pct: float = (
				thick_pct * wall_thickness_occlusion_weight
				+ ray_pct * (1.0 - wall_thickness_occlusion_weight)
			)
			sound_node.set_volume_ratio(occlusion_curve.sample(occlusion_pct))
		else:
			sound_node.set_volume_ratio(0)

		# calculate portal location and volume
		# NOTE: portal location could be set to the avg global position and then
		# calculate volume and attenuation based off the distance from portal to original sound
		if occ.blocked and occ.portal_locs.size() > 0:
			var avg: Vector2 = Vector2.ZERO
			for loc: Vector2 in occ.portal_locs:
				avg += loc
			avg /= occ.portal_locs.size()
			sound_node.portal_sound.global_position = (
				global_position + (avg - global_position).normalized() * 500.0
			)
			sound_node.portal_sound.volume_db = linear_to_db(
				float(occ.portal_locs.size()) / float(occ.num_rays)
			)
		else:
			sound_node.portal_sound.position = Vector2.ZERO
			sound_node.portal_sound.volume_db = -100.0

	var n: int = results.num_rays
	var ec: int = results.echo_count
	reverb_effect.wet = clampf(float(ec) / n, 0.0, 1.0)
	var avg_dist: float = results.echo_dist / float(max(ec, 1))
	reverb_effect.room_size = clampf(avg_dist / max_reverb_distance, 0.0, 1.0) * reverb_effect.wet
	label_room_size.text = "Room Size: %f" % reverb_effect.room_size
	label_inside_outside.text = "Wet: %f" % reverb_effect.wet
	label_reverb_distance.text = "Reverb Distance: %f" % avg_dist
	queue_redraw()


var thread_start_time = 0.0


func _physics_process(_delta: float) -> void:
	if thread.is_started() and not thread.is_alive():
		label_thread_time.text = (
			"Thread Time: %f" % ((Time.get_ticks_msec() - thread_start_time) / 1000.0)
		)
		_apply_results(thread.wait_to_finish() as BackgroundResult)

	if not thread.is_started():
		thread_start_time = Time.get_ticks_msec()
		prev_pos = global_position
		var args := WorkArgs.new()
		args.snapshot = _build_frame_snapshot()
		args.listener_pos = global_position
		args.sound_infos = _build_sound_infos()
		args.num_rays = num_rays
		args.max_bounces = max_bounces
		args.max_los_bounces = max_los_bounces
		args.max_ray_distance = max_ray_distance
		thread.start(_do_background_work.bind(args))


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
				var pair_color := Color.from_hsv(float(i) / max(shortest_list_length, 1), 0.8, 0.9)
				draw_circle(p1, 5, pair_color)
				draw_circle(p2, 5, pair_color)
				draw_line(start_pos, p1, Color.YELLOW_GREEN, DEBUG_RAY_THICKNESS)
				draw_dashed_line(p1, p2, pair_color, DEBUG_RAY_THICKNESS)
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
