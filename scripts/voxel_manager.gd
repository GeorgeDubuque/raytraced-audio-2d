extends Node2D

@export_group("Grid Settings")
@export var cols: int = 10
@export var rows: int = 5
@export var cell_size: int = 64
@export var filled_box_style : StyleBoxFlat

@export_group("Debug Settings")
@export var show_debug_grid: bool = true:
	set(value):
		show_debug_grid = value
		queue_redraw()
@export var line_color: Color = Color(0, 1, 1, 0.5) # Cyan with 50% alpha

var grid: Array[Array] = []

var rectangles : Dictionary = {}

func _ready() -> void:
	_generate_grid()

func _generate_grid() -> void:
	grid.clear()
	for x in cols:
		var column: Array[bool] = []
		column.resize(rows)
		column.fill(false)
		grid.append(column)

func _draw() -> void:
	if not show_debug_grid:
		return
		
	var grid_width = cols * cell_size
	var grid_height = rows * cell_size
	
	# Draw Vertical Lines
	for x in cols + 1:
		var x_pos = x * cell_size
		draw_line(Vector2(x_pos, 0), Vector2(x_pos, grid_height), line_color)
		
	# Draw Horizontal Lines
	for y in rows + 1:
		var y_pos = y * cell_size
		draw_line(Vector2(0, y_pos), Vector2(grid_width, y_pos), line_color)

	
	for rect in rectangles.values():
		draw_style_box(filled_box_style, rect)

var _painting: bool = false
var _paint_value: bool = true

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_painting = event.pressed
			_paint_value = true
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_painting = event.pressed
			_paint_value = false
		if event.pressed:
			_paint_at(event.position)
	elif event is InputEventMouseMotion and _painting:
		_paint_at(event.position)

func _paint_at(pos: Vector2) -> void:
	var grid_pos = Vector2i(pos / float(cell_size))
	if grid_pos.x >= 0 and grid_pos.x < cols and grid_pos.y >= 0 and grid_pos.y < rows:
		set_grid_value(grid_pos, _paint_value)

func set_grid_value(grid_pos: Vector2, value: bool):
	if grid_pos.x < 0 or grid_pos.x >= grid.size():
		return;
	if grid_pos.y < 0 or grid_pos.y >= grid[0].size():
		return;

	grid[grid_pos.x][grid_pos.y] = value
	var target_rect = Rect2(grid_pos * cell_size, Vector2(cell_size, cell_size))
	if(value == true):
		rectangles[grid_pos] = target_rect
	else:
		rectangles.erase(grid_pos)

	queue_redraw()

		
