class_name WindowRainFx
extends Control
## 固定机位窗外雨幕。只负责玻璃外侧的雨线，不读取剧情或电话状态。

signal motion_enabled_changed(is_enabled: bool)

const DEFAULT_RANDOM_SEED: int = 199904
const FAR_RAIN_COUNT: int = 34
const NEAR_RAIN_COUNT: int = 15

@export var random_seed: int = DEFAULT_RANDOM_SEED
@export var motion_enabled: bool = true

var _elapsed_seconds: float = 0.0
var _far_marks: Array[Dictionary] = []
var _near_marks: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rebuild_marks()
	_apply_motion_state()


func _process(delta: float) -> void:
	_elapsed_seconds = fmod(_elapsed_seconds + maxf(delta, 0.0), 3_600.0)
	queue_redraw()


func set_motion_enabled(is_enabled: bool) -> Dictionary:
	motion_enabled = is_enabled
	_apply_motion_state()
	motion_enabled_changed.emit(motion_enabled)
	return {"ok": true, "motion_enabled": motion_enabled}


func is_motion_enabled() -> bool:
	return motion_enabled


func set_random_seed(new_seed: int) -> Dictionary:
	random_seed = new_seed
	_elapsed_seconds = 0.0
	_rebuild_marks()
	queue_redraw()
	return {"ok": true, "random_seed": random_seed}


func get_effect_snapshot() -> Dictionary:
	return {
		"random_seed": random_seed,
		"motion_enabled": motion_enabled,
		"is_processing": is_processing(),
		"is_visible": visible,
		"far_rain_marks": _far_marks.duplicate(true),
		"near_rain_marks": _near_marks.duplicate(true),
	}


func _draw() -> void:
	if not motion_enabled or size.x <= 0.0 or size.y <= 0.0:
		return
	_draw_rain_marks(_far_marks)
	_draw_rain_marks(_near_marks)


func _apply_motion_state() -> void:
	visible = motion_enabled
	set_process(motion_enabled)
	queue_redraw()


func _rebuild_marks() -> void:
	_far_marks.clear()
	_near_marks.clear()
	var random: RandomNumberGenerator = RandomNumberGenerator.new()
	random.seed = random_seed
	_create_marks(random, FAR_RAIN_COUNT, false)
	_create_marks(random, NEAR_RAIN_COUNT, true)


func _create_marks(random: RandomNumberGenerator, count: int, is_near: bool) -> void:
	for index: int in count:
		var speed: float = random.randf_range(0.08, 0.17) if is_near else random.randf_range(0.035, 0.075)
		var length: float = random.randf_range(18.0, 34.0) if is_near else random.randf_range(8.0, 18.0)
		var alpha: float = random.randf_range(0.10, 0.18) if is_near else random.randf_range(0.035, 0.085)
		var width: float = random.randf_range(0.7, 1.15) if is_near else 0.55
		var color: Color = Color(0.47, 0.68, 0.75, alpha) if is_near else Color(0.35, 0.57, 0.66, alpha)
		var mark: Dictionary = {
			"x_ratio": random.randf_range(0.01, 0.99),
			"y_ratio": random.randf_range(0.0, 1.0),
			"speed": speed,
			"length": length,
			"width": width,
			"color": color,
			"phase": float(index) * 0.173 + random.randf_range(0.0, 1.0),
		}
		if is_near:
			_near_marks.append(mark)
		else:
			_far_marks.append(mark)


func _draw_rain_marks(marks: Array[Dictionary]) -> void:
	for mark: Dictionary in marks:
		var length: float = float(mark["length"])
		var y: float = fposmod(float(mark["y_ratio"]) + _elapsed_seconds * float(mark["speed"]), 1.15) * (size.y + length) - length
		var wind_x: float = sin(_elapsed_seconds * 0.48 + float(mark["phase"])) * 1.5
		var x: float = float(mark["x_ratio"]) * size.x + wind_x
		var start: Vector2 = Vector2(x, y)
		var end: Vector2 = Vector2(x - length * 0.12, y + length)
		draw_line(start, end, mark["color"] as Color, float(mark["width"]), true)
